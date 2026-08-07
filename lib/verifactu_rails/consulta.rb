# frozen_string_literal: true

require 'nokogiri'
require_relative 'formato'
require_relative 'registro'
require_relative 'error'

module VerifactuRails
  NS_LRC = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/' \
           'dep/aplicaciones/es/aeat/tike/cont/ws/ConsultaLR.xsd'

  # Consulta de los registros ya anotados (ConsultaLR.xsd).
  #
  # Por qué hace falta un servicio aparte: la respuesta al ENVÍO dice si la AEAT
  # aceptó el registro, no qué queda almacenado, y los estados NO son los mismos.
  # RespuestaSuministro solo conoce Correcto, AceptadoConErrores e Incorrecto;
  # la consulta añade "Anulado", que el canal de envío no sabe expresar. Es decir:
  # que una anulación se anote correctamente y que la factura quede anulada son
  # dos hechos distintos, y el segundo solo se observa desde aquí.
  #
  # Consultar es de solo lectura: no crea registros ni toca la cadena.
  #
  # Va al MISMO endpoint que el envío (VerifactuSOAP): lo que cambia es el
  # elemento del Body, no la URL, así que `Transporte` sirve tal cual.
  class Consulta
    # TipoPeriodoType es mensual: 01-12. No hay periodos trimestrales.
    PERIODOS = %w[01 02 03 04 05 06 07 08 09 10 11 12].freeze
    PATRON_EJERCICIO = /\A\d{4}\z/ # sf:YearType

    attr_reader :nif_obligado, :nombre_obligado, :ejercicio, :periodo,
                :num_serie, :fecha_expedicion, :desde, :hasta,
                :sistema_informatico, :clave_paginacion

    # @param periodo [String, Integer] mes de imputación; 8 y '08' valen igual.
    # @param sistema_informatico [SistemaInformatico, nil] filtra por SIF. Con la
    #   arquitectura de "SIF virtuales" (un NumeroInstalacion por fuente de
    #   facturación) esto es lo que aísla la cadena de una fuente concreta.
    # @param clave_paginacion [IdFactura, nil] la que devolvió la página anterior.
    def initialize(nif_obligado:, nombre_obligado:, ejercicio:, periodo:,
                   num_serie: nil, fecha_expedicion: nil, desde: nil, hasta: nil,
                   sistema_informatico: nil, clave_paginacion: nil)
      @nif_obligado = Formato.nif(nif_obligado, 'NIF del obligado')
      @nombre_obligado = Formato.limitar(nombre_obligado, 'NombreRazon del obligado', 120)
      @ejercicio = validar_ejercicio(ejercicio)
      @periodo = Formato.enumerado(formatear_periodo(periodo), 'Periodo', PERIODOS)
      @num_serie = num_serie && Formato.num_serie(num_serie)
      @fecha_expedicion = fecha_expedicion && Formato.fecha(fecha_expedicion)
      @desde = desde && Formato.fecha(desde)
      @hasta = hasta && Formato.fecha(hasta)
      @sistema_informatico = sistema_informatico &&
                             Formato.objeto(sistema_informatico, 'sistema_informatico',
                                            SistemaInformatico)
      @clave_paginacion = clave_paginacion &&
                          Formato.objeto(clave_paginacion, 'clave_paginacion', IdFactura)

      validar_fechas!
    end

    def to_xml
      constructor = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml['con'].ConsultaFactuSistemaFacturacion('xmlns:con' => NS_LRC, 'xmlns:sum1' => NS_SF) do
          # Cabecera se declara en ConsultaLR, pero su CONTENIDO es de
          # SuministroInformacion: por eso el prefijo cambia al entrar. Con
          # elementFormDefault="qualified" en ambos esquemas, equivocarse aquí
          # invalida el documento aunque el árbol "se vea" bien.
          xml['con'].Cabecera do
            xml['sum1'].IDVersion IDVERSION
            xml['sum1'].ObligadoEmision do
              xml['sum1'].NombreRazon nombre_obligado
              xml['sum1'].NIF nif_obligado
            end
          end
          xml['con'].FiltroConsulta do
            xml['con'].PeriodoImputacion do
              xml['sum1'].Ejercicio ejercicio
              xml['sum1'].Periodo periodo
            end
            xml['con'].NumSerieFactura num_serie if num_serie
            construir_fechas(xml)
            if sistema_informatico
              xml['con'].SistemaInformatico do
                sistema_informatico.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
              end
            end
            if clave_paginacion
              xml['con'].ClavePaginacion do
                clave_paginacion.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
              end
            end
          end
        end
      end
      constructor.to_xml
    end

    private

    # FechaExpedicionConsultaType es un <choice>: o fecha suelta o rango. Sin esta
    # guarda se emitían los dos y el documento salía inválido solo al validar.
    def validar_fechas!
      return unless fecha_expedicion && (desde || hasta)

      raise ValidacionError,
            'fecha_expedicion: y el rango desde:/hasta: se excluyen: el esquema ' \
            'admite una fecha concreta O un rango, no ambos'
    end

    def construir_fechas(xml)
      return unless fecha_expedicion || desde || hasta

      xml['con'].FechaExpedicionFactura do
        if fecha_expedicion
          xml['sum1'].FechaExpedicionFactura fecha_expedicion
        else
          xml['sum1'].RangoFechaExpedicion do
            xml['sum1'].Desde desde if desde
            xml['sum1'].Hasta hasta if hasta
          end
        end
      end
    end

    def validar_ejercicio(valor)
      cadena = valor.to_s
      return cadena if cadena.match?(PATRON_EJERCICIO)

      raise ValidacionError, "Ejercicio debe ser un año de cuatro dígitos: #{valor.inspect}"
    end

    # Se admite el entero por comodidad (periodo: 8), pero el XSD exige dos
    # posiciones: sin rellenar el cero, "8" se rechazaría.
    def formatear_periodo(valor)
      return format('%<mes>02d', mes: valor) if valor.is_a?(Integer)

      valor.to_s
    end
  end

  # Respuesta a una consulta (RespuestaConsultaLR.xsd).
  #
  # Igual que Respuesta: solo lee. Lo que llega de la AEAT es la verdad, y una
  # respuesta que no encaje con lo que esperamos no debe impedir leer el resto.
  #
  # LO QUE DEVUELVE ES UNA FOTO, NO UN LIBRO (comprobado contra preproducción):
  # una fila por FACTURA con su estado ACTUAL, no un histórico de registros de
  # facturación. Si una factura se subsanó, se devuelve la subsanación y el alta
  # original desaparece; si se anuló, se devuelve la anulación con estado
  # "Anulado". Consecuencia práctica: la cadena NO se puede reconstruir entera
  # desde aquí, porque los eslabones sustituidos ya no salen y los registros que
  # encadenaban tras ellos parecen huérfanos aunque la cadena esté intacta.
  class RespuestaConsulta
    NS = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/' \
         'dep/aplicaciones/es/aeat/tike/cont/ws/RespuestaConsultaLR.xsd'
    NS_SF_RESP = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/' \
                 'dep/aplicaciones/es/aeat/tike/cont/ws/SuministroInformacion.xsd'
    NS_SOAP = 'http://schemas.xmlsoap.org/soap/envelope/'

    # OJO: NO son los mismos estados que en RespuestaSuministro. Aquí no existe
    # "Incorrecto" -un registro rechazado no se almacena, así que no se puede
    # consultar- y sí existe "Anulado", que es el estado que da sentido a todo
    # este servicio.
    ESTADOS = %w[Correcto AceptadoConErrores Anulado].freeze

    # Un registro tal y como la AEAT lo tiene guardado.
    Anotado = Struct.new(:id_emisor, :num_serie, :fecha_expedicion, :estado,
                         :timestamp_modificacion, :codigo_error, :descripcion_error,
                         :tipo_factura, :subsanacion, :huella, :primer_registro,
                         :huella_anterior, :num_serie_anterior, :cuota_total,
                         :importe_total, :fecha_hora_gen, :numero_instalacion,
                         keyword_init: true) do
      def correcto? = estado == 'Correcto'
      def aceptado_con_errores? = estado == 'AceptadoConErrores'

      # La factura fue anulada por un registro de anulación posterior. Este
      # estado NO existe en la respuesta al envío.
      def anulado? = estado == 'Anulado'

      def subsanacion? = subsanacion == 'S'
      def primer_registro? = primer_registro == 'S'

      def to_s
        base = "#{num_serie}: #{estado}"
        base += ' (subsanación)' if subsanacion?
        codigo_error ? "#{base} [#{codigo_error}] #{descripcion_error}" : base
      end
    end

    attr_reader :xml, :ejercicio, :periodo, :indicador_paginacion,
                :resultado, :registros, :clave_paginacion

    def initialize(xml)
      @xml = xml
      doc = Nokogiri::XML(xml)
      raiz = doc.at_xpath('//c:RespuestaConsultaFactuSistemaFacturacion', 'c' => NS)

      if raiz.nil?
        raise RespuestaError,
              'La respuesta no contiene RespuestaConsultaFactuSistemaFacturacion. ' \
              "#{resumen_de_fallo(doc)}"
      end

      @ejercicio = texto(raiz, 'c:PeriodoImputacion/c:Ejercicio')
      @periodo = texto(raiz, 'c:PeriodoImputacion/c:Periodo')
      @indicador_paginacion = texto(raiz, 'c:IndicadorPaginacion')
      @resultado = texto(raiz, 'c:ResultadoConsulta')
      @registros = raiz.xpath('c:RegistroRespuestaConsultaFactuSistemaFacturacion', 'c' => NS)
                       .map { |n| leer_registro(n) }
      @clave_paginacion = leer_clave(raiz.at_xpath('c:ClavePaginacion', 'c' => NS))
    end

    def con_datos? = resultado == 'ConDatos'
    def sin_datos? = resultado == 'SinDatos'

    # Quedan más páginas. La siguiente consulta se hace repitiendo el mismo
    # filtro con clave_paginacion:, no cambiando el periodo.
    def hay_mas_paginas? = indicador_paginacion == 'S'

    def anulados = registros.select(&:anulado?)
    def a_subsanar = registros.select(&:aceptado_con_errores?)
    def subsanaciones = registros.select(&:subsanacion?)

    def to_s
      "#{resultado} (#{registros.size} registros: #{anulados.size} anulados, " \
        "#{a_subsanar.size} con errores)#{hay_mas_paginas? ? ', hay más páginas' : ''}"
    end

    private

    def leer_registro(nodo)
      datos = nodo.at_xpath('c:DatosRegistroFacturacion', 'c' => NS)
      estado = nodo.at_xpath('c:EstadoRegistro', 'c' => NS)
      anterior = datos&.at_xpath('c:Encadenamiento/c:RegistroAnterior', 'c' => NS)

      Anotado.new(
        id_emisor: texto(nodo, 'c:IDFactura/sf:IDEmisorFactura'),
        num_serie: texto(nodo, 'c:IDFactura/sf:NumSerieFactura'),
        fecha_expedicion: texto(nodo, 'c:IDFactura/sf:FechaExpedicionFactura'),
        estado: estado && texto(estado, 'c:EstadoRegistro'),
        timestamp_modificacion: estado && texto(estado, 'c:TimestampUltimaModificacion'),
        codigo_error: estado && texto(estado, 'c:CodigoErrorRegistro'),
        descripcion_error: estado && texto(estado, 'c:DescripcionErrorRegistro'),
        tipo_factura: datos && texto(datos, 'c:TipoFactura'),
        subsanacion: datos && texto(datos, 'c:Subsanacion'),
        huella: datos && texto(datos, 'c:Huella'),
        primer_registro: datos && texto(datos, 'c:Encadenamiento/c:PrimerRegistro'),
        huella_anterior: anterior && texto(anterior, 'sf:Huella'),
        num_serie_anterior: anterior && texto(anterior, 'sf:NumSerieFactura'),
        cuota_total: datos && texto(datos, 'c:CuotaTotal'),
        importe_total: datos && texto(datos, 'c:ImporteTotal'),
        fecha_hora_gen: datos && texto(datos, 'c:FechaHoraHusoGenRegistro'),
        numero_instalacion: datos && texto(datos, 'c:SistemaInformatico/sf:NumeroInstalacion')
      )
    end

    # Se devuelve como IdFactura para poder pasarla tal cual a la siguiente
    # Consulta, que es lo único que se hace con ella.
    def leer_clave(nodo)
      return nil if nodo.nil?

      IdFactura.new(
        id_emisor: texto(nodo, 'sf:IDEmisorFactura'),
        num_serie: texto(nodo, 'sf:NumSerieFactura'),
        fecha_expedicion: texto(nodo, 'sf:FechaExpedicionFactura')
      )
    end

    def texto(nodo, ruta)
      nodo.at_xpath(ruta, 'c' => NS, 'sf' => NS_SF_RESP)&.text
    end

    def resumen_de_fallo(doc)
      fault = doc.at_xpath('//soap:Fault', 'soap' => NS_SOAP)
      return "Cuerpo recibido: #{xml.to_s[0, 300]}" if fault.nil?

      "La AEAT devolvió un SOAP Fault #{fault.at_xpath('faultcode')&.text}: " \
        "#{fault.at_xpath('faultstring')&.text}"
    end
  end
end
