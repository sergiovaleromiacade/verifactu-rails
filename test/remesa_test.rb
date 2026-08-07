# frozen_string_literal: true

require_relative 'support/base_datos'
require_relative 'support/esquema'
require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

class RemesaTest < Minitest::Test
  include VerifactuRails

  R  = VerifactuRails::Respuesta::NS
  SF = VerifactuRails::Respuesta::NS_SF

  # Transporte enlatado: guarda el XML que se le pasa y devuelve lo que se le
  # diga. Lo que se prueba aquí es la lógica de la remesa, no el mTLS, que ya
  # está cubierto por transporte_test y comprobado contra el servicio real.
  class TransporteFalso
    attr_reader :enviados

    def initialize(&respuesta)
      @respuesta = respuesta
      @enviados = []
    end

    def enviar(xml)
      @enviados << xml
      { codigo: 200, cuerpo: @respuesta.call(xml, @enviados.size) }
    end
  end

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
    @cadena = Libro::Cadena.abrir!(numero_instalacion: "REM-#{SecureRandom.hex(4)}",
                                   nif_obligado: '89890001K', nombre_obligado: 'Empresa SL')
  end

  def anotar(serie)
    @cadena.anotar_alta!(
      id_emisor: '89890001K', num_serie: serie, fecha_expedicion: Date.today,
      nombre_razon_emisor: 'Empresa SL', tipo_factura: 'F1',
      descripcion_operacion: 'Servicios',
      desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                             tipo_impositivo: BigDecimal('21'),
                             cuota_repercutida: BigDecimal('21.00'))],
      cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
      fecha_hora_gen: Time.now,
      destinatarios: [Destinatario.new(nombre_razon: 'Cliente SL', nif: '89890002E')]
    )
  end

  def linea(serie, estado, codigo: nil, duplicado: nil)
    <<~XML
      <sum:RespuestaLinea>
        <sum:IDFactura>
          <sum1:IDEmisorFactura>89890001K</sum1:IDEmisorFactura>
          <sum1:NumSerieFactura>#{serie}</sum1:NumSerieFactura>
          <sum1:FechaExpedicionFactura>#{Date.today.strftime('%d-%m-%Y')}</sum1:FechaExpedicionFactura>
        </sum:IDFactura>
        <sum:Operacion><sum1:TipoOperacion>Alta</sum1:TipoOperacion></sum:Operacion>
        <sum:EstadoRegistro>#{estado}</sum:EstadoRegistro>
        #{"<sum:CodigoErrorRegistro>#{codigo}</sum:CodigoErrorRegistro>" if codigo}
        #{duplicado}
      </sum:RespuestaLinea>
    XML
  end

  def duplicado(estado)
    <<~XML
      <sum:RegistroDuplicado>
        <sum1:IdPeticionRegistroDuplicado>A-XYZ123</sum1:IdPeticionRegistroDuplicado>
        <sum1:EstadoRegistroDuplicado>#{estado}</sum1:EstadoRegistroDuplicado>
      </sum:RegistroDuplicado>
    XML
  end

  def respuesta(lineas, estado_envio: 'Correcto', espera: 60)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <sum:RespuestaRegFactuSistemaFacturacion xmlns:sum="#{R}" xmlns:sum1="#{SF}">
        <sum:CSV>A-CSV-#{SecureRandom.hex(3)}</sum:CSV>
        <sum:DatosPresentacion>
          <sum1:NIFPresentador>89890001K</sum1:NIFPresentador>
          <sum1:TimestampPresentacion>07-08-2026 12:00:00</sum1:TimestampPresentacion>
        </sum:DatosPresentacion>
        <sum:Cabecera>
          <sum1:ObligadoEmision>
            <sum1:NombreRazon>Empresa SL</sum1:NombreRazon>
            <sum1:NIF>89890001K</sum1:NIF>
          </sum1:ObligadoEmision>
        </sum:Cabecera>
        <sum:TiempoEsperaEnvio>#{espera}</sum:TiempoEsperaEnvio>
        <sum:EstadoEnvio>#{estado_envio}</sum:EstadoEnvio>
        #{lineas.join}
      </sum:RespuestaRegFactuSistemaFacturacion>
    XML
  end

  def remesar(cadena = @cadena, &bloque)
    transporte = TransporteFalso.new(&bloque)
    [Libro::Remesa.new(cadena, transporte: transporte).enviar!, transporte]
  end

  # --- El XML que se manda ---------------------------------------------------

  # Lo que viaja tiene que ser LITERALMENTE lo que se calculó al anotar: si el
  # envío reconstruyera el XML, la huella almacenada y la enviada podrían
  # divergir, y la AEAT recalcula sobre lo que recibe.
  def test_el_xml_enviado_lleva_los_fragmentos_guardados_tal_cual
    uno = anotar('FA/1')
    dos = anotar('FA/2')
    _, transporte = remesar { respuesta([linea('FA/1', 'Correcto'), linea('FA/2', 'Correcto')]) }
    xml = transporte.enviados.first

    assert_includes xml, ">#{uno.huella}<"
    assert_includes xml, ">#{dos.huella}<"
    assert_includes xml, uno.payload.split("\n")[1] # una línea interior del fragmento
  end

  def test_el_envio_por_fragmentos_valida_contra_el_xsd
    anotar('FA/1')
    anotar('FA/2')
    _, transporte = remesar { respuesta([linea('FA/1', 'Correcto'), linea('FA/2', 'Correcto')]) }

    assert_empty Esquema.errores(transporte.enviados.first)
  end

  def test_manda_los_pendientes_en_una_sola_peticion
    3.times { |i| anotar("FA/#{i}") }
    resultado, transporte = remesar do
      respuesta(3.times.map { |i| linea("FA/#{i}", 'Correcto') })
    end

    assert_predicate resultado, :enviado?
    assert_equal 1, transporte.enviados.size
    assert_equal %w[anotado anotado anotado], @cadena.registros.order(:id).pluck(:estado)
  end

  # --- Veredictos ------------------------------------------------------------

  def test_reparte_el_veredicto_registro_a_registro
    anotar('FA/0')
    anotar('FA/1')
    remesar do
      respuesta([linea('FA/0', 'Correcto'),
                 linea('FA/1', 'AceptadoConErrores', codigo: 1105)],
                estado_envio: 'ParcialmenteCorrecto')
    end

    estados = @cadena.registros.order(:id).pluck(:num_serie, :estado, :codigo_error)

    assert_equal [['FA/0', 'anotado', nil], ['FA/1', 'aceptado_con_errores', 1105]], estados
  end

  # Un duplicado es ÉXITO: significa que el registro ya consta, que es lo que se
  # quería. Pasa al reintentar un envío que dio timeout.
  def test_un_duplicado_cuenta_como_anotado
    anotar('FA/1')
    remesar do
      respuesta([linea('FA/1', 'Incorrecto', codigo: 3000, duplicado: duplicado('Correcta'))],
                estado_envio: 'Incorrecto')
    end
    fila = @cadena.registros.first

    assert_equal 'anotado', fila.estado
    assert_includes fila.descripcion_error, 'ya constaba en la AEAT'
    assert_includes fila.descripcion_error, 'Correcta'
  end

  # Pero no se traga el estado del que ya estaba: si figura Anulada, hay un
  # problema real y tiene que quedar escrito.
  def test_un_duplicado_anulado_queda_registrado_en_la_descripcion
    anotar('FA/1')
    remesar do
      respuesta([linea('FA/1', 'Incorrecto', codigo: 3000, duplicado: duplicado('Anulada'))],
                estado_envio: 'Incorrecto')
    end

    assert_includes @cadena.registros.first.descripcion_error, 'Anulada'
  end

  # --- Control de flujo y reintentos ----------------------------------------

  def test_respeta_el_tiempo_de_espera_que_devuelve_la_aeat
    anotar('FA/1')
    remesar { respuesta([linea('FA/1', 'Correcto')], espera: 60) }

    assert_operator @cadena.reload.no_enviar_antes_de, :>, Time.now + 50

    anotar('FA/2')
    resultado, transporte = remesar { respuesta([]) }

    assert_equal :esperando, resultado.estado
    assert_empty transporte.enviados
  end

  def test_sin_pendientes_no_manda_nada
    resultado, transporte = remesar { respuesta([]) }

    assert_equal :nada_pendiente, resultado.estado
    assert_empty transporte.enviados
  end

  # Si la AEAT no da veredicto de un registro, se queda 'enviando' y se reintenta:
  # tras un timeout no se sabe si llegó, y abandonarlo sería peor.
  def test_un_registro_sin_veredicto_se_queda_para_reintentar
    anotar('FA/1')
    anotar('FA/2')
    remesar { respuesta([linea('FA/1', 'Correcto')]) } # falta el veredicto de FA/2

    assert_equal 'enviando', @cadena.registros.order(:id).last.estado

    @cadena.update!(no_enviar_antes_de: nil)
    _, transporte = remesar { respuesta([linea('FA/2', 'Correcto')]) }

    assert_equal 1, transporte.enviados.size
    assert_equal 'anotado', @cadena.registros.order(:id).last.estado
  end

  # Un rechazado NO consta en la AEAT, así que todo lo que encadena detrás apunta
  # a un eslabón que allí no existe. Seguir enviando "funcionaría" -la AEAT no
  # valida el eslabón al recibir- y dejaría una cadena incoherente aceptada en
  # silencio.
  def test_un_rechazo_detiene_la_cadena_en_vez_de_seguir
    anotar('FA/1')
    remesar { respuesta([linea('FA/1', 'Incorrecto', codigo: 1101)], estado_envio: 'Incorrecto') }

    assert_equal 'rechazado', @cadena.registros.first.estado

    anotar('FA/2')
    @cadena.update!(no_enviar_antes_de: nil)
    resultado, transporte = remesar { respuesta([]) }

    assert_equal :bloqueada_por_rechazo, resultado.estado
    assert_empty transporte.enviados
  end

  def test_no_manda_mas_de_mil_registros_por_peticion
    assert_equal 1000, Libro::Remesa::MAXIMO
  end
end
