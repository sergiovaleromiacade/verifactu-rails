# frozen_string_literal: true

# Verificación cruzada contra implementaciones de referencia independientes.
# Si las tres coinciden en todos los casos, la serialización es correcta con
# altísima probabilidad, aunque no tengamos los vectores oficiales de la AEAT.

require 'minitest/autorun'
require 'date'
require 'bigdecimal'
require 'digest'
require_relative '../lib/verifactu_rails/huella'

# Implementación de mybooking-es/verifactu-rb (MIT), cargada tal cual del repo.
require_relative 'support/mybooking_huella'

# Réplica literal de josemmo/Verifactu-PHP :: RegistrationRecord::calculateHash()
module JosemmoRef
  def self.alta(emisor, serie, fecha, tipo, cuota, importe, previa, momento)
    payload  = "IDEmisorFactura=#{emisor}"
    payload += "&NumSerieFactura=#{serie}"
    payload += "&FechaExpedicionFactura=#{fecha.strftime('%d-%m-%Y')}"
    payload += "&TipoFactura=#{tipo}"
    payload += "&CuotaTotal=#{cuota}"
    payload += "&ImporteTotal=#{importe}"
    payload += "&Huella=#{previa || ''}"
    payload += "&FechaHoraHusoGenRegistro=#{momento.strftime('%Y-%m-%dT%H:%M:%S%:z')}"
    Digest::SHA256.hexdigest(payload).upcase
  end
end

class DiferencialTest < Minitest::Test
  CASOS = [
    ['B12345678', 'FA/2026/0001', Date.new(2026, 8, 6),  'F1', '21.00',  '121.00', nil],
    ['B12345678', 'FA/2026/0002', Date.new(2026, 8, 6),  'F1', '21.00',  '121.00', 'A' * 64],
    ['12345678Z', 'T-1',          Date.new(2026, 1, 3),  'F2', '0.00',   '5.50',   'F' * 64],
    ['B98765432', 'R/2026/7',     Date.new(2026, 12, 31), 'R1', '-21.00', '-121.00', '0123456789ABCDEF' * 4],
    ['B11111111', 'FACTURACIÓN/9', Date.new(2026, 3, 15), 'F1', '10.50',  '60.50',  'C' * 64]
  ].freeze

  MOMENTO = Time.new(2026, 8, 6, 12, 30, 15, '+02:00')

  def test_coincide_con_las_dos_referencias
    CASOS.each_with_index do |(emisor, serie, fecha, tipo, cuota, importe, previa), i|
      mia = VerifactuRails::Huella.alta(
        id_emisor: emisor, num_serie: serie, fecha_expedicion: fecha,
        tipo_factura: tipo, cuota_total: BigDecimal(cuota),
        importe_total: BigDecimal(importe), fecha_hora_gen: MOMENTO,
        huella_anterior: previa
      )

      mybooking = Verifactu::Helper::GenerarHuellaRegistroAlta.execute(
        id_emisor_factura: emisor,
        num_serie_factura: serie,
        fecha_expedicion_factura: fecha.strftime('%d-%m-%Y'),
        tipo_factura: tipo,
        cuota_total: cuota,
        importe_total: importe,
        huella: previa,
        fecha_hora_huso_gen_registro: MOMENTO.strftime('%Y-%m-%dT%H:%M:%S%:z')
      )

      josemmo = JosemmoRef.alta(emisor, serie, fecha, tipo, cuota, importe, previa, MOMENTO)

      assert_equal mybooking, mia, "caso #{i}: divergencia con mybooking-es/verifactu-rb"
      assert_equal josemmo,   mia, "caso #{i}: divergencia con josemmo/Verifactu-PHP"
    end
  end

  def test_muestra_aleatoria_amplia
    rng = Random.new(1234)
    500.times do
      emisor  = "B#{rng.rand(10_000_000..99_999_999)}"
      serie   = "#{%w[FA T R FACT].sample(random: rng)}/#{rng.rand(1..99_999)}"
      fecha   = Date.new(2026, rng.rand(1..12), rng.rand(1..28))
      tipo    = %w[F1 F2 R1 R2 R3 R4 R5].sample(random: rng)
      cuota   = format('%.2f', rng.rand(-500.0..500.0))
      importe = format('%.2f', rng.rand(-5000.0..5000.0))
      previa  = rng.rand < 0.2 ? nil : Digest::SHA256.hexdigest(rng.rand.to_s).upcase
      momento = Time.at(rng.rand(1_767_225_600..1_798_761_600), in: '+01:00')

      mia = VerifactuRails::Huella.alta(
        id_emisor: emisor, num_serie: serie, fecha_expedicion: fecha,
        tipo_factura: tipo, cuota_total: BigDecimal(cuota),
        importe_total: BigDecimal(importe), fecha_hora_gen: momento,
        huella_anterior: previa
      )
      josemmo = JosemmoRef.alta(emisor, serie, fecha, tipo, cuota, importe, previa, momento)
      mybooking = Verifactu::Helper::GenerarHuellaRegistroAlta.execute(
        id_emisor_factura: emisor, num_serie_factura: serie,
        fecha_expedicion_factura: fecha.strftime('%d-%m-%Y'), tipo_factura: tipo,
        cuota_total: cuota, importe_total: importe, huella: previa,
        fecha_hora_huso_gen_registro: momento.strftime('%Y-%m-%dT%H:%M:%S%:z')
      )

      assert_equal josemmo, mia
      assert_equal mybooking, mia
    end
  end
end
