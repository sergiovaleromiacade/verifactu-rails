# frozen_string_literal: true

require_relative 'support/esquema'
require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

# Reglas de los ap. 11, 12, 14, 15.1, 15.3 y 15.4 de Validaciones v1.2.2.
# Todas se comprobaron leyendo el PDF, no de memoria: son las que quedaban
# pendientes en doc/FUENTES.md.
class ValidacionesTest < Minitest::Test
  include VerifactuRails

  def sistema
    SistemaInformatico.new(nombre_razon: 'Empresa SL', nif: '89890001K',
                           nombre_sistema: 'TuFactura', id_sistema: '01',
                           version: '1.0.0', numero_instalacion: 'INST-1')
  end

  def detalle(tipo: '21.00', cuota: '21.00', calificacion: 'S1', **extra)
    Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: calificacion,
                tipo_impositivo: BigDecimal(tipo), cuota_repercutida: BigDecimal(cuota),
                **extra)
  end

  def cliente = Destinatario.new(nombre_razon: 'Cliente SL', nif: '89890002E')

  def alta(**extra)
    base = {
      id_emisor: '89890001K', num_serie: 'FA/1', fecha_expedicion: Date.new(2026, 8, 7),
      nombre_razon_emisor: 'Empresa SL', tipo_factura: 'F1',
      descripcion_operacion: 'Servicios', desglose: [detalle],
      cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
      sistema_informatico: sistema, fecha_hora_gen: Time.now,
      destinatarios: [cliente]
    }
    RegistroAlta.new(**base.merge(extra))
  end

  def envio(registro)
    Envio.new(nif_obligado: '89890001K', nombre_obligado: 'Empresa SL',
              entradas: [[registro, nil]]).to_xml
  end

  # --- Ap. 11 y 12: EmitidaPorTerceroODestinatario y Tercero ----------------

  def tercero = Tercero.new(nombre_razon: 'Gestoria SL', nif: '89890002E')

  def test_emitida_por_tercero_exige_el_bloque_tercero
    error = assert_raises(ValidacionError) { alta(emitida_por: 'T') }

    assert_match(/exige el bloque tercero/, error.message)
  end

  def test_el_tercero_no_cabe_sin_declarar_que_emitio_un_tercero
    error = assert_raises(ValidacionError) { alta(tercero: tercero) }

    assert_match(/solo cabe con emitida_por/, error.message)
  end

  # Reachable solo en las simplificadas: en F1/F3/R1-R4 los destinatarios ya son
  # obligatorios por el ap. 13, así que ahí esta regla nunca llega a dispararse.
  def test_emitida_por_el_destinatario_no_cabe_en_una_simplificada
    error = assert_raises(ValidacionError) do
      alta(tipo_factura: 'F2', destinatarios: [], emitida_por: 'D')
    end

    assert_match(/exige destinatarios/, error.message)
  end

  def test_el_tercero_no_puede_ser_el_propio_emisor
    propio = Tercero.new(nombre_razon: 'Empresa SL', nif: '89890001K')
    error = assert_raises(ValidacionError) { alta(emitida_por: 'T', tercero: propio) }

    assert_match(/no puede ser el del emisor/, error.message)
  end

  def test_un_alta_con_tercero_valida_contra_el_xsd
    xml = envio(alta(emitida_por: 'T', tercero: tercero))

    assert_empty Esquema.errores(xml)
    assert_includes xml, '<sum1:EmitidaPorTerceroODestinatario>T<'
    assert_includes xml, 'Gestoria SL'
  end

  # El tercero y el destinatario NO tienen las mismas reglas de identificación:
  # es lo que justifica que IdOtro reciba por parámetro lo que cambia.
  def test_el_tercero_no_admite_no_censado_y_el_destinatario_si
    assert_raises(ValidacionError) do
      Tercero.new(nombre_razon: 'X', id_otro: { codigo_pais: 'ES', id_type: '07', id: 'X1' })
    end

    censado = Destinatario.new(nombre_razon: 'X',
                               id_otro: { codigo_pais: 'ES', id_type: '07', id: 'X1' })

    assert_equal '07', censado.id_type
  end

  def test_desde_espana_el_tercero_solo_admite_pasaporte
    error = assert_raises(ValidacionError) do
      Tercero.new(nombre_razon: 'X', id_otro: { codigo_pais: 'ES', id_type: '04', id: 'X1' })
    end

    assert_match(/solo puede ser 03/, error.message)

    bueno = Tercero.new(nombre_razon: 'X',
                        id_otro: { codigo_pais: 'ES', id_type: '03', id: 'X1' })

    assert_equal '03', bueno.id_type
  end

  # --- Ap. 14: Cupon --------------------------------------------------------

  def test_el_cupon_solo_cabe_en_r1_y_r5
    error = assert_raises(ValidacionError) { alta(cupon: 'S') }

    assert_match(/solo cabe con TipoFactura R1 o R5/, error.message)
  end

  def test_el_cupon_no_admite_un_no_explicito
    error = assert_raises(ValidacionError) do
      alta(tipo_factura: 'R5', tipo_rectificativa: 'I', destinatarios: [], cupon: 'N')
    end

    assert_match(/solo admite 'S'/, error.message)
  end

  def test_una_r5_con_cupon_valida_contra_el_xsd
    xml = envio(alta(tipo_factura: 'R5', tipo_rectificativa: 'I', destinatarios: [],
                     cupon: 'S'))

    assert_empty Esquema.errores(xml)
    assert_includes xml, '<sum1:Cupon>S<'
  end

  # --- Ap. 15.4: la inversión del sujeto pasivo acota el tipo de factura -----

  def test_la_inversion_del_sujeto_pasivo_no_cabe_en_una_simplificada
    inversion = detalle(calificacion: 'S2', tipo: '0.00', cuota: '0.00')
    error = assert_raises(ValidacionError) do
      alta(tipo_factura: 'F2', destinatarios: [], desglose: [inversion],
           cuota_total: BigDecimal('0.00'), importe_total: BigDecimal('100.00'))
    end

    assert_match(/S2 .*no cabe con TipoFactura F2/, error.message)
  end

  # --- Ap. 15.1: ventanas temporales del tipo impositivo --------------------

  # El 5 % fue una rebaja temporal que caducó el 30-09-2024. Como la fecha de
  # expedición no puede ser anterior al 28-10-2024, hoy solo es declarable
  # informando una FechaOperacion dentro de la ventana.
  def test_el_cinco_por_ciento_ya_no_es_declarable_sin_fecha_de_operacion
    error = assert_raises(ValidacionError) do
      alta(desglose: [detalle(tipo: '5.00', cuota: '5.00')],
           cuota_total: BigDecimal('5.00'), importe_total: BigDecimal('105.00'))
    end

    assert_match(/TipoImpositivo 5.00 solo se admite entre 01-07-2022 y 30-09-2024/,
                 error.message)
  end

  def test_el_cinco_por_ciento_vale_con_una_fecha_de_operacion_dentro_de_la_ventana
    registro = alta(fecha_operacion: Date.new(2024, 9, 30),
                    desglose: [detalle(tipo: '5.00', cuota: '5.00')],
                    cuota_total: BigDecimal('5.00'), importe_total: BigDecimal('105.00'))

    assert_empty Esquema.errores(envio(registro))
  end

  def test_un_dia_despues_de_cerrarse_la_ventana_ya_no_vale
    assert_raises(ValidacionError) do
      alta(fecha_operacion: Date.new(2024, 10, 1),
           desglose: [detalle(tipo: '5.00', cuota: '5.00')],
           cuota_total: BigDecimal('5.00'), importe_total: BigDecimal('105.00'))
    end
  end

  def test_los_tipos_permanentes_no_llevan_ventana
    %w[0.00 4.00 10.00 21.00].each do |tipo|
      registro = alta(desglose: [detalle(tipo: tipo, cuota: '0.00')],
                      cuota_total: BigDecimal('0.00'), importe_total: BigDecimal('100.00'))

      assert_empty Esquema.errores(envio(registro)), "#{tipo} debería valer siempre"
    end
  end

  # --- Ap. 15.3: el recargo tiene que cuadrar con el tipo --------------------

  def test_el_recargo_debe_corresponder_al_tipo_impositivo
    error = assert_raises(ValidacionError) do
      alta(desglose: [detalle(tipo_recargo: BigDecimal('1.40'),
                              cuota_recargo: BigDecimal('1.40'))])
    end

    assert_match(/Con TipoImpositivo 21.00.*solo puede ser 5.20 o 1.75/, error.message)
  end

  def test_el_recargo_correcto_pasa
    registro = alta(desglose: [detalle(tipo_recargo: BigDecimal('5.20'),
                                       cuota_recargo: BigDecimal('5.20'))])

    assert_empty Esquema.errores(envio(registro))
  end

  # Fuera de las ventanas que la norma menciona no se impone nada: ser más
  # estricto que la AEAT ya bloqueó casos válidos antes en esta gema.
  def test_fuera_de_ventana_el_cero_por_ciento_no_impone_recargo
    registro = alta(desglose: [detalle(tipo: '0.00', cuota: '0.00',
                                       tipo_recargo: BigDecimal('1.75'),
                                       cuota_recargo: BigDecimal('0.00'))],
                    cuota_total: BigDecimal('0.00'), importe_total: BigDecimal('100.00'))

    assert_empty Esquema.errores(envio(registro))
  end
end
