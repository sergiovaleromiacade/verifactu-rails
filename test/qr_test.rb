# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

# La AEAT no devuelve esta URL en ninguna respuesta: la construye el SIF. El
# documento de especificaciones (v0.5.0) trae un ejemplo resuelto, que aquí se
# usa como vector oficial igual que los tres de la huella.
class QRTest < Minitest::Test
  include VerifactuRails

  # Ap. 4 del PDF, con el caso que el propio documento usa para explicar el URL
  # encoding: un número de serie que contiene "&".
  OFICIAL = 'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR?' \
            'nif=89890001K&numserie=12345678%26G33&fecha=01-01-2024&importe=241.4'

  def test_reproduce_el_ejemplo_oficial_del_pdf
    url = QR.componer(nif: '89890001K', num_serie: '12345678&G33',
                      fecha: '01-01-2024', importe: '241.4', entorno: :pruebas)

    assert_equal OFICIAL, url
  end

  # El contraejemplo del propio PDF: sin codificar, el "&" parte la URL y
  # "G33" se convierte en un parámetro suelto.
  def test_sin_codificar_el_numero_de_serie_partiria_la_url
    url = QR.componer(nif: '89890001K', num_serie: '12345678&G33',
                      fecha: '01-01-2024', importe: '241.4')

    refute_includes url, 'numserie=12345678&G33'
    assert_equal 4, url.split('?').last.split('&').size
  end

  # Formato.num_serie admite espacios, así que esto es alcanzable. Se codifica
  # como %20 y no como "+": los dos son válidos, pero "+" solo significa espacio
  # bajo form-urlencoded y no sabemos cómo lo decodifica la AEAT.
  def test_los_espacios_van_como_por_ciento_veinte
    url = QR.componer(nif: '89890001K', num_serie: 'FA 2026 1',
                      fecha: '01-01-2024', importe: '10.00')

    assert_includes url, 'numserie=FA%202026%201'
    refute_includes url, '+'
  end

  def test_produccion_usa_otro_host_distinto_al_de_los_envios
    url = QR.componer(nif: '89890001K', num_serie: 'FA/1', fecha: '01-01-2024',
                      importe: '10.00', entorno: :produccion)

    assert_includes url, 'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR?'
    # Los envíos van por www1/www10; el cotejo, por www2.
    refute_includes url, 'www1.'
  end

  def test_un_entorno_desconocido_se_rechaza
    assert_raises(ValidacionError) do
      QR.componer(nif: '89890001K', num_serie: 'FA/1', fecha: '01-01-2024',
                  importe: '10.00', entorno: :vaya_usted_a_saber)
    end
  end

  # Los cuatro valores salen del registro ya normalizados, así que la URL se
  # puede construir sin volver a formatear nada.
  def test_desde_un_registro_toma_los_campos_ya_normalizados
    sistema = SistemaInformatico.new(nombre_razon: 'E', nif: '89890001K',
                                     nombre_sistema: 'T', id_sistema: '01',
                                     version: '1.0', numero_instalacion: 'I-1')
    alta = RegistroAlta.new(
      id_emisor: '89890001K', num_serie: 'FA/1', fecha_expedicion: Date.new(2026, 8, 7),
      nombre_razon_emisor: 'E', tipo_factura: 'F2',
      descripcion_operacion: 'S',
      desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                             tipo_impositivo: BigDecimal('21'),
                             cuota_repercutida: BigDecimal('21.00'))],
      cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
      sistema_informatico: sistema, fecha_hora_gen: Time.now
    )

    assert_equal 'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR?nif=89890001K&' \
                 'numserie=FA%2F1&fecha=07-08-2026&importe=121.00',
                 QR.url(alta)
  end
end
