# frozen_string_literal: true

require_relative 'support/esquema'
require 'minitest/autorun'
require 'digest'
require_relative '../lib/verifactu-rails'

class XmlTest < Minitest::Test
  include VerifactuRails

  SF = VerifactuRails::NS_SF
  MOMENTO = Time.new(2026, 8, 6, 12, 30, 15, '+02:00')

  def sistema(**extra)
    SistemaInformatico.new(
      nombre_razon: 'Paraia SL', nif: 'B12345678',
      nombre_sistema: 'MiFactura', id_sistema: '01', version: '0.1.0',
      numero_instalacion: 'INST-1', **extra
    )
  end

  def detalle(**extra)
    Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                tipo_impositivo: BigDecimal('21.00'),
                cuota_repercutida: BigDecimal('21.00'), **extra)
  end

  def alta(**extra)
    RegistroAlta.new(
      id_emisor: 'B12345678', num_serie: 'FA/2026/0001',
      fecha_expedicion: Date.new(2026, 8, 6), nombre_razon_emisor: 'Paraia SL',
      tipo_factura: 'F1', descripcion_operacion: 'Servicios de agosto',
      desglose: [detalle], cuota_total: BigDecimal('21.00'),
      importe_total: BigDecimal('121.00'), sistema_informatico: sistema,
      fecha_hora_gen: MOMENTO, **extra
    )
  end

  def anterior(huella: 'A' * 64)
    RegistroAnterior.new(id_emisor: 'B12345678', num_serie: 'FA/2026/0000',
                         fecha_expedicion: Date.new(2026, 8, 5), huella: huella)
  end

  def envio(entradas)
    Envio.new(nif_obligado: 'B12345678', nombre_obligado: 'Paraia SL',
              entradas: entradas).to_xml
  end

  # --- validación contra el esquema oficial ---------------------------------

  def test_un_alta_valida_contra_el_xsd
    assert_empty Esquema.errores(envio([[alta, nil]]))
  end

  def test_un_alta_encadenada_valida_contra_el_xsd
    assert_empty Esquema.errores(envio([[alta, anterior]]))
  end

  def test_una_anulacion_valida_contra_el_xsd
    baja = RegistroAnulacion.new(
      id_emisor: 'B12345678', num_serie: 'FA/2026/0001',
      fecha_expedicion: Date.new(2026, 8, 6), sistema_informatico: sistema,
      fecha_hora_gen: MOMENTO
    )
    assert_empty Esquema.errores(envio([[baja, anterior]]))
  end

  def test_un_destinatario_extranjero_valida_contra_el_xsd
    fuera = Destinatario.new(nombre_razon: 'Client SARL',
                             id_otro: { codigo_pais: 'FR', id_type: '02',
                                        id: 'FR12345678901' })
    assert_empty Esquema.errores(envio([[alta(destinatarios: [fuera]), nil]]))
  end

  def test_una_operacion_exenta_valida_contra_el_xsd
    linea = Detalle.new(base_imponible: BigDecimal('100.00'), exenta: 'E1')
    registro = alta(desglose: [linea], cuota_total: BigDecimal('0.00'),
                    importe_total: BigDecimal('100.00'))
    assert_empty Esquema.errores(envio([[registro, nil]]))
  end

  # --- el bug número uno del dominio ----------------------------------------

  # Reproduce lo que hace la AEAT: recalcula la huella SOBRE LOS VALORES DEL XML
  # recibido y la compara con la que viaja en el propio documento. Si el
  # generador formateara un importe distinto de como lo formateó la huella, aquí
  # se ve. Se construye la cadena a mano, sin usar Huella, para que sea una
  # comprobación independiente y no una tautología.
  def recalcular_como_la_aeat(doc)
    reg = doc.at_xpath('//sf:RegistroAlta', 'sf' => SF)
    campo = ->(nombre) { reg.at_xpath("sf:#{nombre}", 'sf' => SF)&.text.to_s }
    id = ->(nombre) { reg.at_xpath("sf:IDFactura/sf:#{nombre}", 'sf' => SF).text }
    previa = reg.at_xpath('sf:Encadenamiento/sf:RegistroAnterior/sf:Huella', 'sf' => SF)

    cadena = "IDEmisorFactura=#{id['IDEmisorFactura']}" \
             "&NumSerieFactura=#{id['NumSerieFactura']}" \
             "&FechaExpedicionFactura=#{id['FechaExpedicionFactura']}" \
             "&TipoFactura=#{campo['TipoFactura']}" \
             "&CuotaTotal=#{campo['CuotaTotal']}" \
             "&ImporteTotal=#{campo['ImporteTotal']}" \
             "&Huella=#{previa&.text}" \
             "&FechaHoraHusoGenRegistro=#{campo['FechaHoraHusoGenRegistro']}"
    [Digest::SHA256.hexdigest(cadena).upcase, campo['Huella']]
  end

  def test_la_huella_del_xml_resiste_el_recalculo_de_la_aeat
    [nil, anterior].each do |previa|
      doc = Nokogiri::XML(envio([[alta, previa]]))
      recalculada, declarada = recalcular_como_la_aeat(doc)

      assert_equal recalculada, declarada,
                   "La huella del XML no cuadra con sus propios valores (previa: #{previa.inspect})"
    end
  end

  # Importes con decimales que se prestan a divergir según quién los formatee.
  def test_los_importes_del_xml_son_los_de_la_huella
    registro = alta(cuota_total: BigDecimal('0.125'),
                    importe_total: BigDecimal('2.675'))
    doc = Nokogiri::XML(envio([[registro, nil]]))
    recalculada, declarada = recalcular_como_la_aeat(doc)

    assert_equal recalculada, declarada
    assert_equal '0.13', doc.at_xpath('//sf:CuotaTotal', 'sf' => SF).text
    assert_equal '2.68', doc.at_xpath('//sf:ImporteTotal', 'sf' => SF).text
  end

  # La huella se calcula sobre el valor CRUDO y el XML lo escapa. La AEAT
  # desescapa antes de recalcular, así que ambas cosas son correctas a la vez;
  # este test fija esa asimetría, que es justo donde es fácil equivocarse.
  def test_una_serie_con_ampersand_se_escapa_en_xml_pero_no_en_la_huella
    registro = alta(num_serie: 'FA&2026/1')
    xml = envio([[registro, nil]])

    assert_includes xml, 'FA&amp;2026/1'
    recalculada, declarada = recalcular_como_la_aeat(Nokogiri::XML(xml))
    assert_equal recalculada, declarada
    assert_equal registro.huella(anterior: nil), declarada
  end

  # --- encadenamiento --------------------------------------------------------

  def test_sin_anterior_emite_primer_registro
    doc = Nokogiri::XML(envio([[alta, nil]]))

    assert_equal 'S', doc.at_xpath('//sf:Encadenamiento/sf:PrimerRegistro', 'sf' => SF).text
    assert_nil doc.at_xpath('//sf:Encadenamiento/sf:RegistroAnterior', 'sf' => SF)
  end

  def test_con_anterior_emite_los_cuatro_campos_del_registro_previo
    doc = Nokogiri::XML(envio([[alta, anterior]]))
    previo = doc.at_xpath('//sf:Encadenamiento/sf:RegistroAnterior', 'sf' => SF)

    assert_equal %w[IDEmisorFactura NumSerieFactura FechaExpedicionFactura Huella],
                 previo.element_children.map(&:name)
  end

  def test_una_anulacion_no_puede_iniciar_cadena
    baja = RegistroAnulacion.new(
      id_emisor: 'B12345678', num_serie: 'FA/2026/0001',
      fecha_expedicion: Date.new(2026, 8, 6), sistema_informatico: sistema,
      fecha_hora_gen: MOMENTO
    )
    assert_raises(ArgumentError) { baja.huella(anterior: nil) }
  end

  def test_rechaza_huella_anterior_que_no_sea_sha256_mayusculas
    assert_raises(ArgumentError) { anterior(huella: 'a' * 64) }
    assert_raises(ArgumentError) { anterior(huella: 'ABC') }
  end

  # --- límites del esquema ---------------------------------------------------

  def test_el_desglose_no_admite_mas_de_doce_lineas
    error = assert_raises(ArgumentError) { Desglose.new(Array.new(13) { detalle }) }
    assert_match(/12 líneas/, error.message)
  end

  def test_el_envio_no_admite_mas_de_mil_registros
    entradas = Array.new(1001) { [alta, nil] }
    error = assert_raises(ArgumentError) do
      Envio.new(nif_obligado: 'B12345678', nombre_obligado: 'X', entradas: entradas)
    end
    assert_match(/1000 registros/, error.message)
  end

  def test_el_envio_exige_al_menos_un_registro
    assert_raises(ArgumentError) do
      Envio.new(nif_obligado: 'B12345678', nombre_obligado: 'X', entradas: [])
    end
  end

  # --- reglas propias --------------------------------------------------------

  # Declarar 'N' obligaría a llevar registro de eventos, que esta gema no
  # implementa. No debe poder configurarse.
  def test_el_sistema_declara_siempre_solo_verifactu
    doc = Nokogiri::XML(envio([[alta, nil]]))

    assert_equal 'S', doc.at_xpath('//sf:TipoUsoPosibleSoloVerifactu', 'sf' => SF).text
    refute_respond_to sistema, :solo_verifactu=
  end

  def test_no_se_puede_indicar_multiples_ot_sin_admitir_multi_ot
    assert_raises(ArgumentError) { sistema(multi_ot: false, multiples_ot: true) }
  end

  # --- rectificativas --------------------------------------------------------

  def rectificada
    IdFactura.new(id_emisor: 'B12345678', num_serie: 'FA/2026/0001',
                  fecha_expedicion: Date.new(2026, 8, 1))
  end

  def rectificativa(**extra)
    alta(tipo_factura: 'R1', num_serie: 'RE/2026/0001',
         facturas_rectificadas: [rectificada], **extra)
  end

  def sustitutiva(**extra)
    rectificativa(tipo_rectificativa: 'S',
                  importe_rectificacion: ImporteRectificacion.new(
                    base: BigDecimal('100.00'), cuota: BigDecimal('21.00')
                  ), **extra)
  end

  def test_una_rectificativa_sustitutiva_valida_contra_el_xsd
    assert_empty Esquema.errores(envio([[sustitutiva, nil]]))
  end

  def test_una_rectificativa_incremental_valida_contra_el_xsd
    assert_empty Esquema.errores(envio([[rectificativa(tipo_rectificativa: 'I'), nil]]))
  end

  def test_una_f3_con_facturas_sustituidas_valida_contra_el_xsd
    registro = alta(tipo_factura: 'F3', facturas_sustituidas: [rectificada])
    assert_empty Esquema.errores(envio([[registro, nil]]))
  end

  # El orden de la <sequence> del esquema no perdona.
  def test_los_campos_de_rectificacion_van_en_el_orden_del_esquema
    doc = Nokogiri::XML(envio([[sustitutiva, nil]]))
    nombres = doc.at_xpath('//sf:RegistroAlta', 'sf' => SF).element_children.map(&:name)
    interes = %w[TipoFactura TipoRectificativa FacturasRectificadas
                 ImporteRectificacion DescripcionOperacion]

    assert_equal interes, nombres.select { |n| interes.include?(n) }
  end

  # Una rectificativa sigue siendo un alta: su huella se encadena igual.
  def test_la_huella_de_una_rectificativa_resiste_el_recalculo
    doc = Nokogiri::XML(envio([[sustitutiva, anterior]]))
    recalculada, declarada = recalcular_como_la_aeat(doc)

    assert_equal recalculada, declarada
  end

  def test_una_rectificativa_exige_tipo_rectificativa
    error = assert_raises(ArgumentError) do
      alta(tipo_factura: 'R1', facturas_rectificadas: [rectificada])
    end
    assert_match(/tipo_rectificativa/, error.message)
  end

  def test_una_rectificativa_exige_saber_que_factura_rectifica
    error = assert_raises(ArgumentError) do
      alta(tipo_factura: 'R1', tipo_rectificativa: 'I')
    end
    assert_match(/facturas_rectificadas/, error.message)
  end

  def test_una_factura_normal_no_admite_campos_de_rectificacion
    assert_raises(ArgumentError) { alta(tipo_rectificativa: 'S') }
    assert_raises(ArgumentError) { alta(facturas_rectificadas: [rectificada]) }
  end

  def test_una_sustitutiva_exige_declarar_lo_sustituido
    error = assert_raises(ArgumentError) { rectificativa(tipo_rectificativa: 'S') }
    assert_match(/importe_rectificacion/, error.message)
  end

  # Sus propios importes ya son la diferencia: no hay nada que sustituir.
  def test_una_incremental_no_admite_importe_rectificacion
    error = assert_raises(ArgumentError) do
      rectificativa(tipo_rectificativa: 'I',
                    importe_rectificacion: ImporteRectificacion.new(
                      base: BigDecimal('100.00'), cuota: BigDecimal('21.00')
                    ))
    end
    assert_match(/incremental/, error.message)
  end

  def test_f3_exige_facturas_sustituidas_y_el_resto_no_las_admite
    assert_raises(ArgumentError) { alta(tipo_factura: 'F3') }
    assert_raises(ArgumentError) { alta(facturas_sustituidas: [rectificada]) }
  end

  def test_rechaza_un_tipo_rectificativa_desconocido
    assert_raises(ArgumentError) { rectificativa(tipo_rectificativa: 'X') }
  end

  def test_el_importe_de_rectificacion_tambien_rechaza_float
    assert_raises(ArgumentError) do
      ImporteRectificacion.new(base: 100.0, cuota: BigDecimal('21.00'))
    end
  end

  def test_una_operacion_exenta_no_admite_cuota_repercutida
    assert_raises(ArgumentError) do
      Detalle.new(base_imponible: BigDecimal('100.00'), exenta: 'E1',
                  cuota_repercutida: BigDecimal('21.00'))
    end
  end

  def test_calificacion_y_exenta_son_excluyentes
    assert_raises(ArgumentError) { Detalle.new(base_imponible: BigDecimal('1.00')) }
    assert_raises(ArgumentError) do
      Detalle.new(base_imponible: BigDecimal('1.00'), calificacion: 'S1', exenta: 'E1')
    end
  end

  def test_el_nif_debe_tener_nueve_caracteres
    assert_raises(ArgumentError) { alta(id_emisor: 'B123') }
  end

  def test_rechaza_float_en_los_importes
    assert_raises(ArgumentError) { alta(importe_total: 121.0) }
    assert_raises(ArgumentError) { detalle(base_imponible: 100.0) }
  end

  def test_el_desglose_ayuda_a_cuadrar_totales_sin_imponerlos
    d = Desglose.new([detalle, detalle])

    assert_equal '42.00', d.cuota_total
    assert_equal '200.00', d.base_total
  end
end
