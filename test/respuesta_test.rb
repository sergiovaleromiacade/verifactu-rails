# frozen_string_literal: true

require_relative 'support/esquema'
require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

# Los fixtures se VALIDAN contra RespuestaSuministro.xsd antes de usarlos. Sin
# eso estaríamos probando el parser contra un XML inventado, y un parser que
# acierta con una entrada irreal no sirve de nada el día del primer envío.
class RespuestaTest < Minitest::Test
  include VerifactuRails

  R = VerifactuRails::Respuesta::NS
  SF = VerifactuRails::Respuesta::NS_SF

  def linea_xml(serie:, estado:, codigo: nil, descripcion: nil, duplicado: nil)
    <<~XML
      <sum:RespuestaLinea>
        <sum:IDFactura>
          <sum1:IDEmisorFactura>B12345678</sum1:IDEmisorFactura>
          <sum1:NumSerieFactura>#{serie}</sum1:NumSerieFactura>
          <sum1:FechaExpedicionFactura>06-08-2026</sum1:FechaExpedicionFactura>
        </sum:IDFactura>
        <sum:Operacion><sum1:TipoOperacion>Alta</sum1:TipoOperacion></sum:Operacion>
        <sum:EstadoRegistro>#{estado}</sum:EstadoRegistro>
        #{"<sum:CodigoErrorRegistro>#{codigo}</sum:CodigoErrorRegistro>" if codigo}
        #{"<sum:DescripcionErrorRegistro>#{descripcion}</sum:DescripcionErrorRegistro>" if descripcion}
        #{duplicado}
      </sum:RespuestaLinea>
    XML
  end

  def duplicado_xml(estado)
    <<~XML
      <sum:RegistroDuplicado>
        <sum1:IdPeticionRegistroDuplicado>PET-1</sum1:IdPeticionRegistroDuplicado>
        <sum1:EstadoRegistroDuplicado>#{estado}</sum1:EstadoRegistroDuplicado>
        <sum1:CodigoErrorRegistro>3000</sum1:CodigoErrorRegistro>
        <sum1:DescripcionErrorRegistro>Registro duplicado</sum1:DescripcionErrorRegistro>
      </sum:RegistroDuplicado>
    XML
  end

  def respuesta_xml(estado_envio: 'Correcto', espera: 60, lineas: '', csv: 'CSV-ABC123')
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <sum:RespuestaRegFactuSistemaFacturacion xmlns:sum="#{R}" xmlns:sum1="#{SF}">
        <sum:CSV>#{csv}</sum:CSV>
        <sum:DatosPresentacion>
          <sum1:NIFPresentador>B12345678</sum1:NIFPresentador>
          <sum1:TimestampPresentacion>2026-08-06T12:30:15+02:00</sum1:TimestampPresentacion>
        </sum:DatosPresentacion>
        <sum:Cabecera>
          <sum1:ObligadoEmision>
            <sum1:NombreRazon>Paraia SL</sum1:NombreRazon>
            <sum1:NIF>B12345678</sum1:NIF>
          </sum1:ObligadoEmision>
        </sum:Cabecera>
        <sum:TiempoEsperaEnvio>#{espera}</sum:TiempoEsperaEnvio>
        <sum:EstadoEnvio>#{estado_envio}</sum:EstadoEnvio>
        #{lineas}
      </sum:RespuestaRegFactuSistemaFacturacion>
    XML
  end

  def esquema_respuesta
    @esquema_respuesta ||= Esquema.compilar('RespuestaSuministro.xsd')
  end

  def assert_fixture_valido(xml)
    errores = esquema_respuesta.validate(Nokogiri::XML(xml))
    assert_empty errores, "el fixture no cumple RespuestaSuministro.xsd: #{errores.first(3).join('; ')}"
  end

  # --- fidelidad de los fixtures ---------------------------------------------

  def test_los_fixtures_cumplen_el_esquema_oficial
    assert_fixture_valido respuesta_xml
    assert_fixture_valido respuesta_xml(lineas: linea_xml(serie: 'FA/1', estado: 'Correcto'))
    assert_fixture_valido respuesta_xml(
      estado_envio: 'Incorrecto',
      lineas: linea_xml(serie: 'FA/1', estado: 'Incorrecto', codigo: '1100',
                        descripcion: 'Valor incorrecto', duplicado: duplicado_xml('Correcta'))
    )
  end

  # --- lectura ---------------------------------------------------------------

  def test_lee_la_cabecera_del_envio
    r = Respuesta.new(respuesta_xml)

    assert_predicate r, :correcto?
    assert_equal 'Correcto', r.estado_envio
    assert_equal 60, r.tiempo_espera
    assert_equal 'CSV-ABC123', r.csv
    assert_equal 'B12345678', r.nif_presentador
    assert_equal '2026-08-06T12:30:15+02:00', r.timestamp_presentacion
  end

  def test_lee_cada_linea_con_su_veredicto
    xml = respuesta_xml(
      estado_envio: 'ParcialmenteCorrecto',
      lineas: linea_xml(serie: 'FA/1', estado: 'Correcto') +
              linea_xml(serie: 'FA/2', estado: 'AceptadoConErrores', codigo: '2001',
                        descripcion: 'La huella no coincide') +
              linea_xml(serie: 'FA/3', estado: 'Incorrecto', codigo: '1100',
                        descripcion: 'Valor incorrecto')
    )
    assert_fixture_valido xml
    r = Respuesta.new(xml)

    assert_predicate r, :parcialmente_correcto?
    assert_equal %w[FA/1 FA/2 FA/3], r.lineas.map(&:num_serie)
    assert_equal %w[FA/1 FA/2], r.anotadas.map(&:num_serie)
    assert_equal ['FA/3'], r.rechazadas.map(&:num_serie)
    assert_equal ['FA/2'], r.a_subsanar.map(&:num_serie)
    assert_equal '2001', r.lineas[1].codigo_error
    assert_equal 'La huella no coincide', r.lineas[1].descripcion_error
  end

  # La distinción que más cara sale confundir: "AceptadoConErrores" quedó
  # ANOTADO. Reenviarlo da un rechazo por duplicado; lo que toca es un alta con
  # subsanacion: 'S'.
  def test_aceptado_con_errores_cuenta_como_anotado_y_no_como_fallo
    xml = respuesta_xml(lineas: linea_xml(serie: 'FA/1', estado: 'AceptadoConErrores',
                                          codigo: '2001', descripcion: 'x'))
    linea = Respuesta.new(xml).lineas.first

    assert_predicate linea, :anotado?
    assert_predicate linea, :aceptado_con_errores?
    refute_predicate linea, :incorrecto?
    refute_predicate linea, :correcto?
  end

  def test_lee_el_registro_duplicado_y_si_estaba_anulado
    xml = respuesta_xml(
      estado_envio: 'Incorrecto',
      lineas: linea_xml(serie: 'FA/1', estado: 'Incorrecto', codigo: '3000',
                        descripcion: 'Duplicado', duplicado: duplicado_xml('Anulada'))
    )
    assert_fixture_valido xml
    linea = Respuesta.new(xml).lineas.first

    assert_predicate linea, :duplicado?
    assert_equal 'PET-1', linea.duplicado.id_peticion
    assert_predicate linea.duplicado, :anulado?
  end

  def test_una_respuesta_sin_lineas_no_revienta
    r = Respuesta.new(respuesta_xml)

    assert_empty r.lineas
    assert_empty r.a_subsanar
  end

  # --- control de flujo ------------------------------------------------------

  def test_calcula_cuando_se_puede_volver_a_enviar
    r = Respuesta.new(respuesta_xml(espera: 60))
    desde = Time.new(2026, 8, 6, 12, 0, 0, '+02:00')

    assert_equal desde + 60, r.esperar_hasta(desde)
  end

  # --- errores de transporte -------------------------------------------------

  def test_un_soap_fault_se_explica_en_vez_de_un_error_opaco
    fault = <<~XML
      <?xml version="1.0"?>
      <env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
        <env:Body><env:Fault>
          <faultcode>env:Client</faultcode>
          <faultstring>Certificado no autorizado</faultstring>
        </env:Fault></env:Body>
      </env:Envelope>
    XML
    error = assert_raises(RespuestaError) { Respuesta.new(fault) }

    assert_match(/SOAP Fault/, error.message)
    assert_match(/Certificado no autorizado/, error.message)
  end

  def test_una_respuesta_ininteligible_muestra_lo_recibido
    error = assert_raises(RespuestaError) { Respuesta.new('<html><body>502</body></html>') }
    assert_match(/Cuerpo recibido/, error.message)
  end

  # Los errores de la gema se pueden capturar todos juntos.
  def test_el_error_de_respuesta_es_un_error_de_la_gema
    assert_raises(VerifactuRails::Error) { Respuesta.new('<x/>') }
  end
end
