# frozen_string_literal: true

require 'nokogiri'
require_relative 'error'

module VerifactuRails
  # Respuesta de la AEAT a un envío de registros (RespuestaSuministro.xsd).
  #
  # Solo lee: no valida contra el esquema ni impone reglas de negocio. Lo que
  # llega de la AEAT es la verdad, y una respuesta que no encaje con lo que
  # esperamos no debe impedir leer el resto.
  #
  # El punto que más importa entender: `EstadoRegistro` tiene TRES valores, no
  # dos. "AceptadoConErrores" significa que el registro SÍ quedó anotado en la
  # AEAT pero arrastra un error que hay que subsanar. Tratarlo como fallo lleva
  # a reenviar un registro que ya existe (y a un rechazo por duplicado);
  # tratarlo como éxito deja una obligación pendiente sin que nadie se entere.
  class Respuesta
    NS = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/' \
         'dep/aplicaciones/es/aeat/tike/cont/ws/RespuestaSuministro.xsd'
    NS_SF = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/' \
            'dep/aplicaciones/es/aeat/tike/cont/ws/SuministroInformacion.xsd'
    NS_SOAP = 'http://schemas.xmlsoap.org/soap/envelope/'

    ESTADOS_ENVIO = %w[Correcto ParcialmenteCorrecto Incorrecto].freeze
    ESTADOS_REGISTRO = %w[Correcto AceptadoConErrores Incorrecto].freeze

    # Una línea de la respuesta: el veredicto de un registro concreto.
    Linea = Struct.new(:num_serie, :id_emisor, :fecha_expedicion, :estado,
                       :codigo_error, :descripcion_error, :duplicado,
                       keyword_init: true) do
      def correcto? = estado == 'Correcto'

      # Anotado en la AEAT, pero con un error que obliga a subsanar. NO se
      # reenvía: se manda después un alta con subsanacion: 'S'.
      def aceptado_con_errores? = estado == 'AceptadoConErrores'

      # Rechazado: no consta en la AEAT. Este sí hay que corregir y reenviar.
      def incorrecto? = estado == 'Incorrecto'

      # Quedó anotado, con o sin errores.
      def anotado? = correcto? || aceptado_con_errores?

      def duplicado? = !duplicado.nil?

      def to_s
        base = "#{num_serie}: #{estado}"
        codigo_error ? "#{base} [#{codigo_error}] #{descripcion_error}" : base
      end
    end

    # Estado del registro que ya existía, cuando el rechazo es por duplicado.
    Duplicado = Struct.new(:id_peticion, :estado, :codigo_error,
                           :descripcion_error, keyword_init: true) do
      def anulado? = estado == 'Anulada'
    end

    attr_reader :xml, :csv, :estado_envio, :tiempo_espera, :lineas,
                :nif_presentador, :timestamp_presentacion

    # @param xml [String] cuerpo devuelto por Transporte#enviar
    def initialize(xml)
      @xml = xml
      doc = Nokogiri::XML(xml)
      raiz = doc.at_xpath('//r:RespuestaRegFactuSistemaFacturacion', 'r' => NS)

      if raiz.nil?
        raise RespuestaError,
              "La respuesta no contiene RespuestaRegFactuSistemaFacturacion. " \
              "#{resumen_de_fallo(doc)}"
      end

      @csv = texto(raiz, 'r:CSV')
      @estado_envio = texto(raiz, 'r:EstadoEnvio')
      @tiempo_espera = texto(raiz, 'r:TiempoEsperaEnvio')&.to_i
      @nif_presentador = texto(raiz, 'r:DatosPresentacion/sf:NIFPresentador')
      @timestamp_presentacion = texto(raiz, 'r:DatosPresentacion/sf:TimestampPresentacion')
      @lineas = raiz.xpath('r:RespuestaLinea', 'r' => NS).map { |n| leer_linea(n) }
    end

    def correcto? = estado_envio == 'Correcto'
    def parcialmente_correcto? = estado_envio == 'ParcialmenteCorrecto'
    def incorrecto? = estado_envio == 'Incorrecto'

    def anotadas = lineas.select(&:anotado?)
    def rechazadas = lineas.select(&:incorrecto?)

    # Las que quedaron anotadas pero obligan a subsanar. Es la lista que hay que
    # mirar cuando el envío sale "Correcto" y uno se relaja: un envío puede ser
    # globalmente correcto y aun así contener registros con esta marca.
    def a_subsanar = lineas.select(&:aceptado_con_errores?)

    # Segundos que hay que esperar antes del siguiente envío, o acumular hasta
    # el límite de lote, lo que ocurra primero.
    def esperar_hasta(desde = nil)
      return nil if tiempo_espera.nil?

      (desde || Time.now) + tiempo_espera
    end

    # El recuento es de LOS REGISTROS DE ESTE ENVÍO, no de la cadena: la AEAT
    # responde sobre lo que le mandaste en esta petición. Una cadena de tres
    # eslabones puede haberse construido en tres envíos de un registro cada uno.
    def to_s
      registros = lineas.size == 1 ? '1 registro en este envío' : "#{lineas.size} registros en este envío"
      "#{estado_envio} (#{registros}: #{anotadas.size} anotados, " \
        "#{a_subsanar.size} a subsanar, #{rechazadas.size} rechazados)"
    end

    private

    def leer_linea(nodo)
      Linea.new(
        num_serie: texto(nodo, 'r:IDFactura/sf:NumSerieFactura'),
        id_emisor: texto(nodo, 'r:IDFactura/sf:IDEmisorFactura'),
        fecha_expedicion: texto(nodo, 'r:IDFactura/sf:FechaExpedicionFactura'),
        estado: texto(nodo, 'r:EstadoRegistro'),
        codigo_error: texto(nodo, 'r:CodigoErrorRegistro'),
        descripcion_error: texto(nodo, 'r:DescripcionErrorRegistro'),
        duplicado: leer_duplicado(nodo.at_xpath('r:RegistroDuplicado', 'r' => NS))
      )
    end

    def leer_duplicado(nodo)
      return nil if nodo.nil?

      Duplicado.new(
        id_peticion: texto(nodo, 'sf:IdPeticionRegistroDuplicado'),
        estado: texto(nodo, 'sf:EstadoRegistroDuplicado'),
        codigo_error: texto(nodo, 'sf:CodigoErrorRegistro'),
        descripcion_error: texto(nodo, 'sf:DescripcionErrorRegistro')
      )
    end

    def texto(nodo, ruta)
      nodo.at_xpath(ruta, 'r' => NS, 'sf' => NS_SF)&.text
    end

    # Un fallo de servicio llega como SOAP Fault, no como RespuestaSuministro.
    # Sin esto el usuario solo vería "no contiene RespuestaRegFactu...".
    def resumen_de_fallo(doc)
      fault = doc.at_xpath('//soap:Fault', 'soap' => NS_SOAP)
      return "Cuerpo recibido: #{xml.to_s[0, 300]}" if fault.nil?

      codigo = fault.at_xpath('faultcode')&.text
      motivo = fault.at_xpath('faultstring')&.text
      "La AEAT devolvió un SOAP Fault #{codigo}: #{motivo}"
    end
  end

  class RespuestaError < StandardError
    include Error
  end
end
