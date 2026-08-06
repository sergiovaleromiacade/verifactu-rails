# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative 'certificado'

module VerifactuRails
  class TransporteError < StandardError; end

  # Cliente HTTP con autenticación mutua TLS contra el servicio VERI*FACTU.
  #
  # Sin Savon: el servicio es un único endpoint con un sobre SOAP fijo, así que
  # Net::HTTP de la stdlib sobra. Nos ahorra httpi, wasabi, gyoku, akami y nori.
  class Transporte
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
        raise ArgumentError, "Entorno inválido: #{entorno.inspect} (usa :pruebas o :produccion)"
      end

      @certificado = certificado
      @entorno = entorno
      @sello = sello.nil? ? certificado.sello? : sello
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

    def envolver(xml_registro)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="#{SOAP_NS}">
          <soapenv:Header/>
          <soapenv:Body>#{xml_registro}</soapenv:Body>
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
          'Aporta la cadena de la CA en ca_file. No uses VERIFY_NONE: ' \
          "(#{error.message})"
      else
        "Error TLS contra #{uri.host}: #{error.message}"
      end
    end
  end
end
