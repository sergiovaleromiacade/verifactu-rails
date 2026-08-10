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
  # --- Ap. 15.6.1 a 15.6.11: la clave de régimen ata la calificación --------
  #
  # Cada clave restringe qué cabe en su misma línea. Se prueba el caso que pasa
  # y el que no: una validación que solo se ejercita por el lado que falla no
  # demuestra que deje trabajar al caso legítimo, que es como se bloquean
  # facturas válidas.

  def sujeta(clave, **extra)
    Detalle.new(base_imponible: BigDecimal('100.00'), clave_regimen: clave,
                calificacion: 'S1', tipo_impositivo: BigDecimal('21.00'),
                cuota_repercutida: BigDecimal('21.00'), **extra)
  end

  def no_sujeta(clave, calificacion, **extra)
    Detalle.new(base_imponible: BigDecimal('100.00'), clave_regimen: clave,
                calificacion: calificacion, **extra)
  end

  def exenta_de(clave, codigo = 'E1', **extra)
    Detalle.new(base_imponible: BigDecimal('100.00'), clave_regimen: clave,
                exenta: codigo, **extra)
  end

  def test_regimen_02_exportacion_solo_admite_exenta
    exenta_de('02', 'E2') # no levanta

    error = assert_raises(ValidacionError) { sujeta('02') }
    assert_match(/02.*solo admite OperacionExenta/, error.message)
  end

  def test_regimen_03_rebu_admite_s1_y_exenta_pero_no_otra_calificacion
    sujeta('03')
    exenta_de('03') # el art. 137.Dos.5ª LIVA contempla exenciones en REBU

    error = assert_raises(ValidacionError) { no_sujeta('03', 'N1') }
    assert_match(/03.*solo admite CalificacionOperacion S1/, error.message)
  end

  def test_regimen_04_oro_exige_s2_o_exenta
    # S2 exige además tipo y cuota a cero, ambos informados (ap. 15.4).
    Detalle.new(base_imponible: BigDecimal('100.00'), clave_regimen: '04',
                calificacion: 'S2', tipo_impositivo: BigDecimal('0.00'),
                cuota_repercutida: BigDecimal('0.00'))
    exenta_de('04')

    error = assert_raises(ValidacionError) { sujeta('04') }
    assert_match(/04.*S2 o una operación exenta/, error.message)
  end

  def test_regimen_07_criterio_de_caja_veta_calificaciones_y_exenciones
    sujeta('07')
    exenta_de('07', 'E1')

    assert_match(/07.*no admite CalificacionOperacion N1/,
                 assert_raises(ValidacionError) { no_sujeta('07', 'N1') }.message)
    assert_match(/07.*no admite OperacionExenta E2/,
                 assert_raises(ValidacionError) { exenta_de('07', 'E2') }.message)
  end

  def test_regimen_08_exige_n2
    no_sujeta('08', 'N2')

    error = assert_raises(ValidacionError) { sujeta('08') }
    assert_match(/08.*exige CalificacionOperacion N2/, error.message)
  end

  # "Siempre debe ir relleno": una línea exenta tampoco cumple.
  def test_regimen_08_no_se_conforma_con_una_exenta
    error = assert_raises(ValidacionError) { exenta_de('08') }
    assert_match(/exige CalificacionOperacion N2/, error.message)
  end

  def test_regimen_11_arrendamiento_solo_admite_el_21
    sujeta('11')

    error = assert_raises(ValidacionError) do
      Detalle.new(base_imponible: BigDecimal('100.00'), clave_regimen: '11',
                  calificacion: 'S1', tipo_impositivo: BigDecimal('10.00'),
                  cuota_repercutida: BigDecimal('10.00'))
    end
    assert_match(/11.*solo admite TipoImpositivo 21\.00/, error.message)
  end

  # La norma restringe qué tipo cabe, no obliga a informarlo: un arrendamiento
  # exento no lleva tipo y no debe bloquearse.
  def test_regimen_11_sin_tipo_impositivo_no_se_bloquea
    exenta_de('11')
  end

  def test_regimen_20_con_igic_exige_n2
    no_sujeta('20', 'N2', impuesto: '03')

    error = assert_raises(ValidacionError) { sujeta('20', impuesto: '03') }
    assert_match(/20 con IGIC.*exige CalificacionOperacion N2/, error.message)
  end

  # LO QUE MÁS IMPORTA DE TODO ESTE BLOQUE. En IPSI las claves 18, 19 y 20
  # significan otra cosa (art. 73 de la Ordenanza de Ceuta, exentas interiores y
  # estimación objetiva), y la norma acota estas reglas a IVA e IGIC. Aplicarlas
  # a IPSI sería inventarse restricciones sobre una lista distinta.
  def test_en_ipsi_las_reglas_de_regimen_no_aplican
    sujeta('20', impuesto: '02') # con IGIC esto exigiría N2
    sujeta('11', impuesto: '02') # con IVA esto exigiría el 21
    sujeta('08', impuesto: '02') # con IVA esto exigiría N2
  end

  # --- Ap. 15.6.4, 15.6.7 y 15.6.9: las que miran fuera de la línea ---------

  def test_regimen_06_no_cabe_en_una_simplificada
    error = assert_raises(ValidacionError) do
      alta(tipo_factura: 'F2', destinatarios: nil, desglose: [sujeta('06')])
    end
    assert_match(/06.*no cabe con TipoFactura F2/, error.message)
  end

  # No es que falte implementarla: es que no se puede cumplir sin
  # BaseImponibleACoste, que la gema no emite. Se para y se dice por qué.
  def test_regimen_06_se_para_porque_exige_un_campo_que_no_emitimos
    error = assert_raises(ValidacionError) { alta(desglose: [sujeta('06')]) }
    assert_match(/BaseImponibleACoste/, error.message)
  end

  def test_regimen_10_exige_f1_y_destinatarios_con_nif
    alta(desglose: [no_sujeta('10', 'N1')])

    assert_match(/10.*exige TipoFactura F1/,
                 assert_raises(ValidacionError) do
                   alta(tipo_factura: 'R1', tipo_rectificativa: 'I',
                        desglose: [no_sujeta('10', 'N1')])
                 end.message)

    extranjero = Destinatario.new(nombre_razon: 'ACME GmbH',
                                  id_otro: { codigo_pais: 'DE', id_type: '02',
                                             id: 'DE123456789' })
    assert_match(/10.*identifiquen por NIF/,
                 assert_raises(ValidacionError) do
                   alta(destinatarios: [extranjero], desglose: [no_sujeta('10', 'N1')])
                 end.message)
  end

  def aapp = Destinatario.new(nombre_razon: 'Ayuntamiento', nif: 'P4600000H')

  def test_regimen_14_aapp_exige_fecha_posterior_y_nif_de_administracion
    alta(destinatarios: [aapp], desglose: [sujeta('14')],
         fecha_operacion: Date.new(2026, 9, 1))

    assert_match(/14.*exige FechaOperacion/,
                 assert_raises(ValidacionError) do
                   alta(destinatarios: [aapp], desglose: [sujeta('14')])
                 end.message)

    assert_match(/posterior a la de expedición/,
                 assert_raises(ValidacionError) do
                   alta(destinatarios: [aapp], desglose: [sujeta('14')],
                        fecha_operacion: Date.new(2026, 8, 1))
                 end.message)

    assert_match(/empiece por P, Q, S, V/,
                 assert_raises(ValidacionError) do
                   alta(desglose: [sujeta('14')], fecha_operacion: Date.new(2026, 9, 1))
                 end.message)
  end

  def test_regimen_14_no_cabe_en_una_simplificada
    error = assert_raises(ValidacionError) do
      alta(tipo_factura: 'F2', destinatarios: nil, desglose: [sujeta('14')],
           fecha_operacion: Date.new(2026, 9, 1))
    end
    assert_match(/14.*exige TipoFactura F1, R1, R2, R3, R4/, error.message)
  end

end
