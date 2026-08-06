# frozen_string_literal: true

require 'minitest/autorun'
require 'date'
require 'bigdecimal'
require_relative '../lib/verifactu_rails/huella'

class HuellaTest < Minitest::Test
  # Caso base reutilizado. Fecha con offset de Madrid en agosto (+02:00).
  ALTA = {
    id_emisor: 'B12345678',
    num_serie: 'FA/2026/0001',
    fecha_expedicion: Date.new(2026, 8, 6),
    tipo_factura: 'F1',
    cuota_total: BigDecimal('21.00'),
    importe_total: BigDecimal('121.00'),
    fecha_hora_gen: Time.new(2026, 8, 6, 12, 30, 15, '+02:00'),
    huella_anterior: nil
  }.freeze

  # --- Serialización: el contrato exacto con la AEAT -------------------------

  def test_cadena_de_alta_campo_a_campo
    esperada = 'IDEmisorFactura=B12345678' \
               '&NumSerieFactura=FA/2026/0001' \
               '&FechaExpedicionFactura=06-08-2026' \
               '&TipoFactura=F1' \
               '&CuotaTotal=21.00' \
               '&ImporteTotal=121.00' \
               '&Huella=' \
               '&FechaHoraHusoGenRegistro=2026-08-06T12:30:15+02:00'
    assert_equal esperada, cadena_alta(ALTA)
  end

  def test_huella_es_sha256_hex_mayusculas
    huella = VerifactuRails::Huella.alta(**ALTA)
    assert_match(/\A[0-9A-F]{64}\z/, huella)
    assert_equal Digest::SHA256.hexdigest(cadena_alta(ALTA)).upcase, huella
  end

  def test_los_valores_no_se_escapan
    # La barra de la serie NO debe convertirse en %2F. Es explícito en la spec.
    assert_includes cadena_alta(ALTA.merge(num_serie: 'A/1')), 'NumSerieFactura=A/1'
  end

  # --- Encadenamiento --------------------------------------------------------

  def test_primer_registro_lleva_huella_vacia
    assert_includes cadena_alta(ALTA), '&Huella=&'
  end

  def test_encadenamiento_cambia_la_huella
    previa = VerifactuRails::Huella.alta(**ALTA)
    segunda = VerifactuRails::Huella.alta(**ALTA.merge(num_serie: 'FA/2026/0002',
                                                  huella_anterior: previa))
    refute_equal previa, segunda
  end

  def test_rechaza_huella_anterior_en_minusculas
    minuscula = VerifactuRails::Huella.alta(**ALTA).downcase
    assert_raises(ArgumentError) { VerifactuRails::Huella.alta(**ALTA.merge(huella_anterior: minuscula)) }
  end

  def test_anulacion_exige_huella_anterior
    assert_raises(ArgumentError) do
      VerifactuRails::Huella.anulacion(id_emisor: 'B12345678', num_serie: 'FA/2026/0001',
                                  fecha_expedicion: Date.new(2026, 8, 6),
                                  fecha_hora_gen: ALTA[:fecha_hora_gen],
                                  huella_anterior: nil)
    end
  end

  def test_cadena_de_anulacion_usa_campos_propios
    cadena = VerifactuRails::Huella.serializar(
      { 'IDEmisorFacturaAnulada' => 'B12345678',
        'NumSerieFacturaAnulada' => 'FA/2026/0001',
        'FechaExpedicionFacturaAnulada' => '06-08-2026',
        'Huella' => 'A' * 64,
        'FechaHoraHusoGenRegistro' => '2026-08-06T12:30:15+02:00' },
      VerifactuRails::Huella::CAMPOS_ANULACION
    )
    assert cadena.start_with?('IDEmisorFacturaAnulada=')
    refute_includes cadena, 'TipoFactura'
    refute_includes cadena, 'ImporteTotal'
  end

  # --- Importes: la fuente número uno de rechazos ----------------------------

  def test_importes_siempre_con_dos_decimales
    cadena = cadena_alta(ALTA.merge(cuota_total: BigDecimal('21'),
                                    importe_total: BigDecimal('121.5')))
    assert_includes cadena, 'CuotaTotal=21.00'
    assert_includes cadena, 'ImporteTotal=121.50'
  end

  def test_rechaza_float
    assert_raises(ArgumentError) { VerifactuRails::Huella.alta(**ALTA.merge(importe_total: 121.0)) }
  end

  def test_redondeo_half_up_no_bancario
    assert_equal '0.13', VerifactuRails::Importe.formatear(BigDecimal('0.125'))
    assert_equal '2.68', VerifactuRails::Importe.formatear(BigDecimal('2.675'))
  end

  def test_importe_negativo_admitido_para_rectificativas
    assert_equal '-121.00', VerifactuRails::Importe.formatear(BigDecimal('-121.00'))
  end

  def test_menos_cero_se_normaliza
    assert_equal '0.00', VerifactuRails::Importe.formatear(BigDecimal('-0.001'))
  end

  def test_acepta_coma_decimal_en_string
    assert_equal '121.50', VerifactuRails::Importe.formatear('121,50')
  end

  # --- Fechas y husos --------------------------------------------------------

  def test_fecha_en_formato_dd_mm_yyyy_con_ceros
    assert_includes cadena_alta(ALTA.merge(fecha_expedicion: Date.new(2026, 1, 3))),
                    'FechaExpedicionFactura=03-01-2026'
  end

  # OJO con la entrada: Time.new(..., '+00:00') NO es un Time en UTC (utc? es
  # false) y se serializa con offset aunque el código usara iso8601, así que con
  # ese valor el test no podía fallar nunca. El caso peligroso de verdad es
  # Time.utc, que es el único que Ruby serializa como "Z".
  def test_un_time_utc_se_serializa_con_offset_no_con_z
    utc = Time.utc(2026, 8, 6, 10, 30, 15)
    assert_predicate utc, :utc?, 'la entrada debe ser UTC de verdad o el test no prueba nada'

    assert_equal '2026-08-06T10:30:15+00:00',
                 VerifactuRails::Formato.marca_temporal(utc)

    cadena = cadena_alta(ALTA.merge(fecha_hora_gen: utc))
    assert_includes cadena, 'FechaHoraHusoGenRegistro=2026-08-06T10:30:15+00:00'
    refute_includes cadena, 'Z'
  end

  # Rails entrega ActiveSupport::TimeWithZone, cuyo iso8601 también rinde "Z" en
  # UTC. No dependemos de activesupport, así que se imita lo esencial: un objeto
  # que responde a strftime y está en UTC.
  def test_un_time_convertido_a_utc_tampoco_lleva_z
    cadena = cadena_alta(ALTA.merge(fecha_hora_gen: Time.new(2026, 8, 6, 12, 30, 15, '+02:00').utc))
    assert_includes cadena, 'FechaHoraHusoGenRegistro=2026-08-06T10:30:15+00:00'
    refute_includes cadena, 'Z'
  end

  def test_horario_de_invierno_madrid
    cadena = cadena_alta(ALTA.merge(fecha_hora_gen: Time.new(2026, 1, 15, 9, 0, 0, '+01:00')))
    assert_includes cadena, 'FechaHoraHusoGenRegistro=2026-01-15T09:00:00+01:00'
  end

  # --- Validación de entrada -------------------------------------------------

  def test_rechaza_espacios_al_borde
    assert_raises(ArgumentError) { VerifactuRails::Huella.alta(**ALTA.merge(num_serie: ' FA/1 ')) }
  end

  def test_rechaza_campos_vacios
    assert_raises(ArgumentError) { VerifactuRails::Huella.alta(**ALTA.merge(id_emisor: '')) }
  end

  # La AEAT NO admite esta serie: NumSerieFactura se limita a ASCII 32-126, y
  # RegistroAlta la rechaza. Aquí se usa a propósito porque Huella es una
  # primitiva que debe poder hashear cualquier registro, incluido uno ajeno, y
  # porque el multibyte UTF-8 es donde más fácil divergen las implementaciones:
  # la cadena se codifica en UTF-8 antes de hashear (Especificaciones v0.1.2,
  # ap. 3).
  def test_utf8_en_serie
    huella = VerifactuRails::Huella.alta(**ALTA.merge(num_serie: 'FACTURACIÓN/1'))
    assert_match(/\A[0-9A-F]{64}\z/, huella)

    assert_raises(ArgumentError, 'RegistroAlta sí debe rechazarla') do
      VerifactuRails::Formato.num_serie('FACTURACIÓN/1')
    end
  end

  # --- Determinismo ----------------------------------------------------------

  def test_es_determinista
    assert_equal VerifactuRails::Huella.alta(**ALTA), VerifactuRails::Huella.alta(**ALTA)
  end

  def test_cualquier_cambio_altera_la_huella
    base = VerifactuRails::Huella.alta(**ALTA)
    variantes = {
      id_emisor: 'B87654321',
      num_serie: 'FA/2026/0002',
      fecha_expedicion: Date.new(2026, 8, 7),
      tipo_factura: 'F2',
      cuota_total: BigDecimal('21.01'),
      importe_total: BigDecimal('121.01')
    }
    variantes.each do |campo, valor|
      refute_equal base, VerifactuRails::Huella.alta(**ALTA.merge(campo => valor)),
                   "cambiar #{campo} debería cambiar la huella"
    end
  end

  private

  # Delega en lib/. Antes reconstruía la cadena con strftime propio, y eso dejaba
  # ciegos a todos los tests que la usan: se podía cambiar Formato.fecha o
  # Formato.marca_temporal y ninguno se enteraba, porque comparaban la
  # reimplementación del test contra sí misma.
  def cadena_alta(attrs)
    VerifactuRails::Huella.cadena_alta(**attrs)
  end
end
