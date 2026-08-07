# frozen_string_literal: true

require_relative 'support/esquema'
require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

# Igual que en respuesta_test: los fixtures se VALIDAN contra
# RespuestaConsultaLR.xsd antes de usarlos. Un parser que acierta con un XML
# inventado no sirve de nada el día de la primera consulta real.
class ConsultaTest < Minitest::Test
  include VerifactuRails

  C = VerifactuRails::RespuestaConsulta::NS
  SF = VerifactuRails::RespuestaConsulta::NS_SF_RESP

  def sistema
    SistemaInformatico.new(nombre_razon: 'Empresa SL', nif: '89890001K',
                           nombre_sistema: 'TuFactura', id_sistema: '01',
                           version: '1.0.0', numero_instalacion: 'CAMP-1')
  end

  def consulta(**extra)
    Consulta.new(nif_obligado: '89890001K', nombre_obligado: 'Empresa SL',
                 ejercicio: '2026', periodo: '08', **extra)
  end

  # --- La petición ----------------------------------------------------------

  def test_la_consulta_minima_valida_contra_el_xsd
    assert_empty Esquema.errores_consulta(consulta.to_xml)
  end

  def test_la_consulta_con_todos_los_filtros_valida_contra_el_xsd
    xml = consulta(num_serie: 'CAMP/1', sistema_informatico: sistema,
                   clave_paginacion: IdFactura.new(id_emisor: '89890001K',
                                                   num_serie: 'CAMP/1',
                                                   fecha_expedicion: Date.new(2026, 8, 7)))
              .to_xml

    assert_empty Esquema.errores_consulta(xml)
  end

  def test_el_rango_de_fechas_valida_contra_el_xsd
    xml = consulta(desde: Date.new(2026, 8, 1), hasta: Date.new(2026, 8, 31)).to_xml

    assert_empty Esquema.errores_consulta(xml)
    assert_includes xml, 'RangoFechaExpedicion'
  end

  # El filtro por SIF es lo que aísla la cadena de una fuente concreta cuando se
  # usa un NumeroInstalacion por fuente ("SIF virtuales").
  def test_el_filtro_por_sif_lleva_el_numero_de_instalacion
    doc = Nokogiri::XML(consulta(sistema_informatico: sistema).to_xml)
    instalacion = doc.at_xpath('//con:SistemaInformatico/sum1:NumeroInstalacion',
                               'con' => VerifactuRails::NS_LRC, 'sum1' => VerifactuRails::NS_SF)

    assert_equal 'CAMP-1', instalacion.text
  end

  # FechaExpedicionConsultaType es un <choice>. Sin la guarda se emitían los dos
  # y el documento solo fallaba al validar, lejos de la causa.
  def test_una_fecha_concreta_y_un_rango_se_excluyen
    error = assert_raises(ValidacionError) do
      consulta(fecha_expedicion: Date.new(2026, 8, 7), desde: Date.new(2026, 8, 1))
    end

    assert_match(/se excluyen/, error.message)
  end

  def test_el_periodo_entero_se_rellena_a_dos_posiciones
    assert_equal '08', Consulta.new(nif_obligado: '89890001K', nombre_obligado: 'Empresa SL',
                                    ejercicio: 2026, periodo: 8).periodo
  end

  def test_un_periodo_fuera_de_la_lista_se_rechaza
    assert_raises(ValidacionError) { consulta(periodo: '13') }
  end

  def test_un_ejercicio_que_no_es_un_ano_se_rechaza
    assert_raises(ValidacionError) { consulta(ejercicio: '26') }
  end

  # --- La respuesta ---------------------------------------------------------

  def registro_xml(serie:, estado:, subsanacion: nil, encadenamiento:, codigo: nil)
    <<~XML
      <con:RegistroRespuestaConsultaFactuSistemaFacturacion>
        <con:IDFactura>
          <sum1:IDEmisorFactura>89890001K</sum1:IDEmisorFactura>
          <sum1:NumSerieFactura>#{serie}</sum1:NumSerieFactura>
          <sum1:FechaExpedicionFactura>07-08-2026</sum1:FechaExpedicionFactura>
        </con:IDFactura>
        <con:DatosRegistroFacturacion>
          #{"<con:Subsanacion>#{subsanacion}</con:Subsanacion>" if subsanacion}
          <con:TipoFactura>F1</con:TipoFactura>
          <con:CuotaTotal>21.00</con:CuotaTotal>
          <con:ImporteTotal>121.00</con:ImporteTotal>
          <con:Encadenamiento>#{encadenamiento}</con:Encadenamiento>
          <con:SistemaInformatico>
            <sum1:NombreRazon>Empresa SL</sum1:NombreRazon>
            <sum1:NIF>89890001K</sum1:NIF>
            <sum1:NombreSistemaInformatico>TuFactura</sum1:NombreSistemaInformatico>
            <sum1:IdSistemaInformatico>01</sum1:IdSistemaInformatico>
            <sum1:Version>1.0.0</sum1:Version>
            <sum1:NumeroInstalacion>CAMP-1</sum1:NumeroInstalacion>
            <sum1:TipoUsoPosibleSoloVerifactu>S</sum1:TipoUsoPosibleSoloVerifactu>
            <sum1:TipoUsoPosibleMultiOT>N</sum1:TipoUsoPosibleMultiOT>
            <sum1:IndicadorMultiplesOT>N</sum1:IndicadorMultiplesOT>
          </con:SistemaInformatico>
          <con:FechaHoraHusoGenRegistro>2026-08-07T11:52:25+02:00</con:FechaHoraHusoGenRegistro>
          <con:TipoHuella>01</con:TipoHuella>
          <con:Huella>#{'A' * 64}</con:Huella>
        </con:DatosRegistroFacturacion>
        <con:EstadoRegistro>
          <con:TimestampUltimaModificacion>2026-08-07T11:53:00+02:00</con:TimestampUltimaModificacion>
          <con:EstadoRegistro>#{estado}</con:EstadoRegistro>
          #{"<con:CodigoErrorRegistro>#{codigo}</con:CodigoErrorRegistro>" if codigo}
        </con:EstadoRegistro>
      </con:RegistroRespuestaConsultaFactuSistemaFacturacion>
    XML
  end

  def primer_registro = '<con:PrimerRegistro>S</con:PrimerRegistro>'

  def tras(serie, huella)
    <<~XML
      <con:RegistroAnterior>
        <sum1:IDEmisorFactura>89890001K</sum1:IDEmisorFactura>
        <sum1:NumSerieFactura>#{serie}</sum1:NumSerieFactura>
        <sum1:FechaExpedicionFactura>07-08-2026</sum1:FechaExpedicionFactura>
        <sum1:Huella>#{huella}</sum1:Huella>
      </con:RegistroAnterior>
    XML
  end

  def respuesta_xml(registros, paginacion: 'N', resultado: 'ConDatos', clave: nil)
    <<~XML
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
        <con:ResultadoConsulta>#{resultado}</con:ResultadoConsulta>
        #{registros.join}
        #{clave}
      </con:RespuestaConsultaFactuSistemaFacturacion>
    XML
  end

  def respuesta_de_ejemplo
    respuesta_xml([
                    registro_xml(serie: 'CAMP/1', estado: 'Correcto', encadenamiento: primer_registro),
                    registro_xml(serie: 'CAMP/2', estado: 'Anulado',
                                 encadenamiento: tras('CAMP/1', 'A' * 64)),
                    registro_xml(serie: 'CAMP/3', estado: 'AceptadoConErrores', subsanacion: 'S',
                                 codigo: 1105, encadenamiento: tras('CAMP/2', 'A' * 64))
                  ])
  end

  # Guardián del resto: si el fixture deja de ser válido, los tests que lo usan
  # dejan de significar nada aunque sigan en verde.
  def test_el_fixture_de_respuesta_es_valido_contra_el_xsd
    assert_empty Esquema.errores_respuesta_consulta(respuesta_de_ejemplo)
  end

  def test_lee_los_registros_y_el_resultado
    r = RespuestaConsulta.new(respuesta_de_ejemplo)

    assert_predicate r, :con_datos?
    assert_equal 3, r.registros.size
    assert_equal %w[CAMP/1 CAMP/2 CAMP/3], r.registros.map(&:num_serie)
    assert_equal '2026', r.ejercicio
    assert_equal '08', r.periodo
  end

  # El motivo de existir de todo este servicio: "Anulado" no aparece en la
  # respuesta al ENVÍO, así que sin consulta no hay forma de saber que una
  # anulación surtió efecto.
  def test_lee_el_estado_anulado_que_la_respuesta_de_envio_no_sabe_expresar
    r = RespuestaConsulta.new(respuesta_de_ejemplo)

    refute_includes VerifactuRails::Respuesta::ESTADOS_REGISTRO, 'Anulado'
    assert_equal %w[CAMP/2], r.anulados.map(&:num_serie)
    assert_predicate r.registros[1], :anulado?
    refute_predicate r.registros[0], :anulado?
  end

  def test_lee_la_subsanacion_y_el_error_pendiente
    r = RespuestaConsulta.new(respuesta_de_ejemplo)
    tercero = r.registros[2]

    assert_predicate tercero, :subsanacion?
    assert_predicate tercero, :aceptado_con_errores?
    assert_equal '1105', tercero.codigo_error
    assert_equal %w[CAMP/3], r.subsanaciones.map(&:num_serie)
    assert_equal %w[CAMP/3], r.a_subsanar.map(&:num_serie)
  end

  # Esto es lo que permite reconstruir la cadena TAL Y COMO LA GUARDÓ LA AEAT,
  # que es la única forma de detectar una bifurcación: al enviar no se detecta.
  def test_lee_el_encadenamiento_almacenado
    r = RespuestaConsulta.new(respuesta_de_ejemplo)

    assert_predicate r.registros[0], :primer_registro?
    assert_nil r.registros[0].huella_anterior
    refute_predicate r.registros[1], :primer_registro?
    assert_equal 'CAMP/1', r.registros[1].num_serie_anterior
    assert_equal 'A' * 64, r.registros[1].huella_anterior
    assert_equal 'CAMP-1', r.registros[1].numero_instalacion
    assert_equal '2026-08-07T11:53:00+02:00', r.registros[1].timestamp_modificacion
  end

  def test_una_consulta_sin_datos_no_trae_registros
    r = RespuestaConsulta.new(respuesta_xml([], resultado: 'SinDatos'))

    assert_predicate r, :sin_datos?
    assert_empty r.registros
    refute_predicate r, :hay_mas_paginas?
  end

  # La clave se devuelve como IdFactura para poder pasarla tal cual a la
  # siguiente Consulta, que es lo único que se hace con ella.
  def test_la_paginacion_devuelve_una_clave_reutilizable
    clave = <<~XML
      <con:ClavePaginacion>
        <sum1:IDEmisorFactura>89890001K</sum1:IDEmisorFactura>
        <sum1:NumSerieFactura>CAMP/3</sum1:NumSerieFactura>
        <sum1:FechaExpedicionFactura>07-08-2026</sum1:FechaExpedicionFactura>
      </con:ClavePaginacion>
    XML
    r = RespuestaConsulta.new(respuesta_xml([registro_xml(serie: 'CAMP/1', estado: 'Correcto',
                                                          encadenamiento: primer_registro)],
                                            paginacion: 'S', clave: clave))

    assert_predicate r, :hay_mas_paginas?
    assert_equal 'CAMP/3', r.clave_paginacion.num_serie

    siguiente = consulta(clave_paginacion: r.clave_paginacion)

    assert_empty Esquema.errores_consulta(siguiente.to_xml)
  end

  def test_un_soap_fault_se_explica_en_vez_de_hablar_del_elemento_que_falta
    fault = <<~XML
      <?xml version="1.0"?>
      <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
        <soapenv:Body><soapenv:Fault>
          <faultcode>soapenv:Server</faultcode>
          <faultstring>Codigo[102].Error interno</faultstring>
        </soapenv:Fault></soapenv:Body>
      </soapenv:Envelope>
    XML
    error = assert_raises(RespuestaError) { RespuestaConsulta.new(fault) }

    assert_match(/SOAP Fault/, error.message)
    assert_match(/Error interno/, error.message)
  end
end
