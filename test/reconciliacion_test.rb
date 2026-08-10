# frozen_string_literal: true

require_relative 'support/base_datos'
require_relative 'support/esquema'
require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

# Reconciliación del libro contra lo que la AEAT tiene anotado.
#
# Las respuestas enlatadas se VALIDAN contra RespuestaConsultaLR.xsd antes de
# usarlas. Un parser que acierta con un XML que la AEAT nunca emitiría no prueba
# nada, y aquí se está decidiendo si una factura consta o no consta remitida.
class ReconciliacionTest < Minitest::Test
  include VerifactuRails

  C  = VerifactuRails::RespuestaConsulta::NS
  SF = VerifactuRails::RespuestaConsulta::NS_SF_RESP

  # Fija, no Date.today: el periodo consultado forma parte de lo que se prueba y
  # no debe cambiar según el día en que se ejecute la suite.
  FECHA = Date.new(2026, 8, 7)
  FECHA_AEAT = '07-08-2026'
  INSTALACION = 'RECON-1'

  def setup
    BaseDatos.preparar!
    BaseDatos.limpiar!
    Libro.configure do |c|
      c.productor_nombre = 'Empresa SL'
      c.productor_nif    = '89890001K'
      c.nombre_sistema   = 'TuFactura'
      c.id_sistema       = '01'
      c.version          = '1.0.0'
      c.entorno          = :pruebas
    end
    @cadena = Libro::Cadena.abrir!(numero_instalacion: INSTALACION,
                                   nif_obligado: '89890001K',
                                   nombre_obligado: 'Empresa SL')
  end

  attr_reader :cadena

  # --- Casos que cuadran ----------------------------------------------------

  def test_lo_anotado_a_ambos_lados_no_da_divergencias
    r = anotar('FA/1', estado: 'anotado')
    informe = revisar(fila(serie: 'FA/1', huella: r.huella))

    assert_predicate informe, :cuadra?
    assert_equal 1, informe.facturas_locales
    assert_equal 1, informe.filas_aeat
  end

  # El caso que define el diseño. Dos registros locales sobre la MISMA factura
  # (el alta y su anulación) contra UNA sola fila de la AEAT, que es lo que
  # devuelve el servicio: una foto por factura, no el histórico. Se compara
  # contra el registro vigente -el último-, así que esto tiene que cuadrar.
  def test_una_anulacion_cuadra_contra_la_unica_fila_que_devuelve_la_aeat
    anotar('FA/1', estado: 'anotado')
    anulacion = cadena.anotar_anulacion!(id_emisor: '89890001K', num_serie: 'FA/1',
                                         fecha_expedicion: FECHA, fecha_hora_gen: Time.now)
    anulacion.update!(estado: 'anotado')

    informe = revisar(fila(serie: 'FA/1', huella: anulacion.huella, estado: 'Anulado'))

    assert_predicate informe, :cuadra?
  end

  # Lo que aún no se ha enviado no tiene por qué constar, y un registro
  # RECHAZADO no se almacena en la AEAT: su ausencia es lo correcto. Si esto
  # fallara, cada reconciliación produciría divergencias falsas por diseño.
  def test_lo_no_enviado_y_lo_rechazado_no_cuentan_como_divergencia
    anotar('FA/1', estado: 'pendiente')
    anotar('FA/2', estado: 'enviando')
    anotar('FA/3', estado: 'rechazado')

    informe = revisar

    assert_predicate informe, :cuadra?
  end

  # --- Divergencias ---------------------------------------------------------

  def test_anotado_en_el_libro_que_la_aeat_no_devuelve
    anotar('FA/1', estado: 'anotado')

    d = unica_divergencia(revisar)

    assert_equal :no_consta, d.tipo
    assert_equal 'FA/1', d.num_serie
  end

  def test_la_aeat_guarda_otra_huella
    anotar('FA/1', estado: 'anotado')

    d = unica_divergencia(revisar(fila(serie: 'FA/1', huella: 'B' * 64)))

    assert_equal :huella_distinta, d.tipo
    assert_match(/#{'B' * 64}/, d.detalle)
  end

  def test_la_aeat_la_da_por_anulada_y_el_libro_no
    r = anotar('FA/1', estado: 'anotado')

    d = unica_divergencia(revisar(fila(serie: 'FA/1', huella: r.huella, estado: 'Anulado')))

    assert_equal :estado_distinto, d.tipo
    assert_match(/Anulado/, d.detalle)
  end

  def test_consta_en_la_aeat_pero_el_libro_la_cree_sin_enviar
    r = anotar('FA/1', estado: 'enviando')

    d = unica_divergencia(revisar(fila(serie: 'FA/1', huella: r.huella)))

    assert_equal :consta_sin_enviar, d.tipo
    assert_match(/huella coincide/, d.detalle)
  end

  def test_factura_en_la_aeat_que_el_libro_no_conoce
    d = unica_divergencia(revisar(fila(serie: 'AJENA/9', huella: 'C' * 64)))

    assert_equal :solo_en_aeat, d.tipo
    assert_equal 'AJENA/9', d.num_serie
  end

  # --- Aislamiento por instalación ------------------------------------------

  # El filtro por SistemaInformatico se manda en la consulta, pero que el
  # servidor lo aplique NO está confirmado contra el servicio real. Si no lo
  # aplicase, la respuesta traería las facturas de todas las instalaciones del
  # obligado y cada tienda ajena aparecería como :solo_en_aeat. Por eso se filtra
  # también en cliente, y esto es lo que lo demuestra.
  def test_las_filas_de_otra_instalacion_se_ignoran_y_se_cuentan
    r = anotar('FA/1', estado: 'anotado')

    informe = revisar(fila(serie: 'FA/1', huella: r.huella),
                      fila(serie: 'OTRA/1', huella: 'D' * 64, instalacion: 'TIENDA-2'))

    assert_predicate informe, :cuadra?
    assert_equal 1, informe.ajenas
    assert_match(/1 de otra instalación/, informe.to_s)
  end

  # --- Paginación -----------------------------------------------------------

  def test_recorre_todas_las_paginas
    a = anotar('FA/1', estado: 'anotado')
    b = anotar('FA/2', estado: 'anotado')

    transporte = TransporteFalso.new([
                                       respuesta_xml([fila(serie: 'FA/1', huella: a.huella)],
                                                     paginacion: 'S', clave: 'FA/1'),
                                       respuesta_xml([fila(serie: 'FA/2', huella: b.huella)])
                                     ])
    informe = Libro::Reconciliacion.new(cadena, transporte: transporte)
                                   .revisar(ejercicio: 2026, periodo: 8)

    assert_equal 2, transporte.peticiones
    assert_predicate informe, :cuadra?
  end

  # Una respuesta que dice "hay más páginas" pero no manda clave dejaría al job
  # pidiendo la misma página para siempre contra la AEAT, que además avisa de que
  # no se le mande carga. Se corta.
  def test_paginacion_sin_clave_no_deja_un_bucle_infinito
    r = anotar('FA/1', estado: 'anotado')
    transporte = TransporteFalso.new(
      [respuesta_xml([fila(serie: 'FA/1', huella: r.huella)], paginacion: 'S')], repetir: true
    )

    informe = Libro::Reconciliacion.new(cadena, transporte: transporte)
                                   .revisar(ejercicio: 2026, periodo: 8)

    assert_equal 1, transporte.peticiones
    assert_predicate informe, :cuadra?
    refute_predicate informe, :truncado?
  end

  # --- Andamiaje ------------------------------------------------------------

  # Devuelve las respuestas que se le den, en orden, y cuenta las peticiones.
  class TransporteFalso
    attr_reader :peticiones

    def initialize(respuestas, repetir: false)
      @respuestas = respuestas
      @repetir = repetir
      @peticiones = 0
    end

    def enviar(_xml)
      @peticiones += 1
      cuerpo = @repetir ? @respuestas.first : @respuestas.shift
      { codigo: 200, cuerpo: cuerpo }
    end
  end

  def anotar(serie, estado:)
    registro = cadena.anotar_alta!(
      id_emisor: '89890001K', num_serie: serie, fecha_expedicion: FECHA,
      nombre_razon_emisor: 'Empresa SL', tipo_factura: 'F1',
      descripcion_operacion: 'Servicios',
      desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                             tipo_impositivo: BigDecimal('21'),
                             cuota_repercutida: BigDecimal('21.00'))],
      cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
      fecha_hora_gen: Time.now,
      destinatarios: [Destinatario.new(nombre_razon: 'Cliente SL', nif: '89890002E')]
    )
    registro.update!(estado: estado)
    registro
  end

  def revisar(*filas)
    transporte = TransporteFalso.new([respuesta_xml(filas)])
    Libro::Reconciliacion.new(cadena, transporte: transporte)
                         .revisar(ejercicio: 2026, periodo: 8)
  end

  def unica_divergencia(informe)
    assert_equal 1, informe.divergencias.size,
                 "se esperaba una divergencia y hubo #{informe.divergencias.map(&:to_s)}"
    informe.divergencias.first
  end

  def fila(serie:, huella:, estado: 'Correcto', instalacion: INSTALACION)
    <<~XML
      <con:RegistroRespuestaConsultaFactuSistemaFacturacion>
        <con:IDFactura>
          <sum1:IDEmisorFactura>89890001K</sum1:IDEmisorFactura>
          <sum1:NumSerieFactura>#{serie}</sum1:NumSerieFactura>
          <sum1:FechaExpedicionFactura>#{FECHA_AEAT}</sum1:FechaExpedicionFactura>
        </con:IDFactura>
        <con:DatosRegistroFacturacion>
          <con:TipoFactura>F1</con:TipoFactura>
          <con:CuotaTotal>21</con:CuotaTotal>
          <con:ImporteTotal>121</con:ImporteTotal>
          <con:Encadenamiento><con:PrimerRegistro>S</con:PrimerRegistro></con:Encadenamiento>
          <con:SistemaInformatico>
            <sum1:NombreRazon>Empresa SL</sum1:NombreRazon>
            <sum1:NIF>89890001K</sum1:NIF>
            <sum1:NombreSistemaInformatico>TuFactura</sum1:NombreSistemaInformatico>
            <sum1:IdSistemaInformatico>01</sum1:IdSistemaInformatico>
            <sum1:Version>1.0.0</sum1:Version>
            <sum1:NumeroInstalacion>#{instalacion}</sum1:NumeroInstalacion>
            <sum1:TipoUsoPosibleSoloVerifactu>S</sum1:TipoUsoPosibleSoloVerifactu>
            <sum1:TipoUsoPosibleMultiOT>N</sum1:TipoUsoPosibleMultiOT>
            <sum1:IndicadorMultiplesOT>N</sum1:IndicadorMultiplesOT>
          </con:SistemaInformatico>
          <con:FechaHoraHusoGenRegistro>2026-08-07T11:52:25+02:00</con:FechaHoraHusoGenRegistro>
          <con:TipoHuella>01</con:TipoHuella>
          <con:Huella>#{huella}</con:Huella>
        </con:DatosRegistroFacturacion>
        <con:EstadoRegistro>
          <con:TimestampUltimaModificacion>2026-08-07T11:53:00+02:00</con:TimestampUltimaModificacion>
          <con:EstadoRegistro>#{estado}</con:EstadoRegistro>
        </con:EstadoRegistro>
      </con:RegistroRespuestaConsultaFactuSistemaFacturacion>
    XML
  end

  def respuesta_xml(filas, paginacion: 'N', clave: nil)
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <con:RespuestaConsultaFactuSistemaFacturacion xmlns:con="#{C}" xmlns:sum1="#{SF}">
        <con:Cabecera>
          <sum1:IDVersion>1.0</sum1:IDVersion>
          <sum1:ObligadoEmision>
            <sum1:NombreRazon>Empresa SL</sum1:NombreRazon>
            <sum1:NIF>89890001K</sum1:NIF>
          </sum1:ObligadoEmision>
        </con:Cabecera>
        <con:PeriodoImputacion>
          <con:Ejercicio>2026</con:Ejercicio>
          <con:Periodo>08</con:Periodo>
        </con:PeriodoImputacion>
        <con:IndicadorPaginacion>#{paginacion}</con:IndicadorPaginacion>
        <con:ResultadoConsulta>#{filas.empty? ? 'SinDatos' : 'ConDatos'}</con:ResultadoConsulta>
        #{filas.join}
        #{clave_xml(clave)}
      </con:RespuestaConsultaFactuSistemaFacturacion>
    XML
    validar!(xml)
    xml
  end

  def clave_xml(clave)
    return '' if clave.nil?

    <<~XML
      <con:ClavePaginacion>
        <sum1:IDEmisorFactura>89890001K</sum1:IDEmisorFactura>
        <sum1:NumSerieFactura>#{clave}</sum1:NumSerieFactura>
        <sum1:FechaExpedicionFactura>#{FECHA_AEAT}</sum1:FechaExpedicionFactura>
      </con:ClavePaginacion>
    XML
  end

  def validar!(xml)
    errores = Esquema.respuesta_consulta_lr.validate(Nokogiri::XML(xml))
    return if errores.empty?

    flunk("La respuesta enlatada no valida contra RespuestaConsultaLR.xsd: #{errores.join('; ')}")
  end
end
