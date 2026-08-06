# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative 'certificado'
require_relative 'error'
require_relative 'formato'

module VerifactuRails
  class TransporteError < StandardError
    include Error
  end

  # Cliente HTTP con autenticación mutua TLS contra el servicio VERI*FACTU.
  #
  # Sin Savon: el servicio es un único endpoint con un sobre SOAP fijo, así que
  # Net::HTTP de la stdlib sobra. Nos ahorra httpi, wasabi, gyoku, akami y nori.
  class Transporte
    # Preproducción y producción se corresponden uno a uno: prewww1 <-> www1,
    # prewww2 <-> www2, prewww10 <-> www10 (este último, el de certificado de
    # sello). Fuente: portal de pruebas externas de la AEAT.
    #
    # Aviso operativo del propio portal: preproducción es para pruebas puntuales,
    # NO para pruebas masivas ni para validaciones integradas en procesos de
    # producción. Un uso que consideren abusivo puede acabar en bloqueo.
    ENDPOINTS = {
      [:pruebas, false]    => 'https://prewww1.aeat.es/wlpl/TIKE-CONT/ws/SistemaFacturacion/VerifactuSOAP',
      [:pruebas, true]     => 'https://prewww10.aeat.es/wlpl/TIKE-CONT/ws/SistemaFacturacion/VerifactuSOAP',
      [:produccion, false] => 'https://www1.agenciatributaria.gob.es/wlpl/TIKE-CONT/ws/SistemaFacturacion/VerifactuSOAP',
      [:produccion, true]  => 'https://www10.agenciatributaria.gob.es/wlpl/TIKE-CONT/ws/SistemaFacturacion/VerifactuSOAP'
    }.freeze

    SOAP_NS = 'http://schemas.xmlsoap.org/soap/envelope/'

    attr_reader :certificado, :entorno, :url

    # @param sello [Boolean, nil] fuerza el endpoint de sello de entidad.
    #   Si es nil se deduce del propio certificado.
    def initialize(certificado:, entorno: :pruebas, sello: nil, url: nil,
                   ca_file: nil, timeout: 30)
      unless %i[pruebas produccion].include?(entorno)
        raise ValidacionError, "Entorno inválido: #{entorno.inspect} (usa :pruebas o :produccion)"
      end

      @certificado = Formato.objeto(certificado, 'certificado', Certificado)
      @entorno = entorno
      # Sin normalizar, un sello: 'S' llegaba a ENDPOINTS.fetch([entorno, 'S']) y
      # daba un KeyError, justo al lado de la comprobación de entorno que sí da
      # un error del dominio.
      @sello = sello.nil? ? @certificado.sello? : Formato.si_no(sello, 'sello') == 'S'
      @url = url || ENDPOINTS.fetch([entorno, @sello])
      @ca_file = ca_file
      @timeout = timeout
    end

    def sello? = @sello

    # Envía el XML del registro ya construido. Devuelve la respuesta cruda:
    # el parseo es responsabilidad de la capa superior.
    def enviar(xml_registro)
      peticion = Net::HTTP::Post.new(uri)
      peticion['Content-Type'] = 'text/xml; charset=utf-8'
      peticion['SOAPAction'] = '""'
      peticion.body = envolver(xml_registro)

      respuesta = cliente.request(peticion)
      { codigo: respuesta.code.to_i, cuerpo: respuesta.body }
    rescue OpenSSL::SSL::SSLError => e
      raise TransporteError, mensaje_ssl(e)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TransporteError, "Timeout contra #{uri.host}: #{e.class}"
    end

    # Una declaración <?xml?> solo puede ir al principio del documento, y
    # Envio#to_xml emite la suya. Incrustarla tal cual dentro del Body producía
    # un sobre MAL FORMADO con dos declaraciones, que la AEAT contestó con
    # "Codigo[102].Error interno en el servidor": el fallo era de parseo, no de
    # validación, así que el mensaje no orientaba en absoluto.
    DECLARACION_XML = /\A\s*<\?xml[^>]*\?>\s*/

    def envolver(xml_registro)
      cuerpo = xml_registro.to_s.sub(DECLARACION_XML, '')
      # document/literal según el WSDL: el Body lleva directamente el elemento,
      # sin envoltorio de operación.
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="#{SOAP_NS}">
          <soapenv:Header/>
          <soapenv:Body>#{cuerpo}</soapenv:Body>
        </soapenv:Envelope>
      XML
    end

    def cliente
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.cert = certificado.certificado
      http.key = certificado.clave
      http.extra_chain_cert = certificado.cadena if certificado.cadena.any?
      # NUNCA VERIFY_NONE. Si falla la verificación, el arreglo es aportar la
      # cadena de la CA correcta en ca_file, no desactivar la comprobación.
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ca_file = @ca_file if @ca_file
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http
    end

    private

    def uri = @uri ||= URI.parse(@url)

    def mensaje_ssl(error)
      if error.message.include?('certificate verify failed')
        "Fallo al verificar el certificado de servidor de #{uri.host}. " \
          'Desde la renovación de noviembre de 2025 la AEAT usa CA públicas ' \
          '(Entrust/Sectigo bajo USERTrust RSA), así que la causa habitual NO es ' \
          'que falte la cadena: mira si el almacén de confianza del sistema está ' \
          'anticuado o si un proxy corporativo intercepta el TLS. Si aun así ' \
          'necesitas anclar la cadena, pásala en ca_file. No uses VERIFY_NONE: ' \
          "(#{error.message})"
      else
        "Error TLS contra #{uri.host}: #{error.message}"
      end
    end
  end
end
