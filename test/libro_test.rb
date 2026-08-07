# frozen_string_literal: true

require_relative 'support/base_datos'
require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

class LibroTest < Minitest::Test
  include VerifactuRails

  def setup
    skip "Sin base de datos: #{BaseDatos.motivo}" unless BaseDatos.preparar!
    BaseDatos.limpiar!
    Libro.configure do |c|
      c.productor_nombre = 'Empresa SL'
      c.productor_nif    = '89890001K'
      c.nombre_sistema   = 'TuFactura'
      c.id_sistema       = '01'
      c.version          = '1.0.0'
      c.entorno          = :pruebas
    end
  end

  def cadena(instalacion = "INST-#{SecureRandom.hex(4)}")
    Libro::Cadena.abrir!(numero_instalacion: instalacion,
                         nif_obligado: '89890001K', nombre_obligado: 'Empresa SL')
  end

  # Manipulación por SQL crudo. attr_readonly bloquea hasta update_column, así
  # que para simular a alguien tocando la base de datos hay que ir por debajo del
  # modelo, que es exactamente lo que haría.
  def alterar!(registro, columna, valor)
    Libro::Registro.connection.execute(
      "UPDATE verifactu_registros SET #{columna} = #{Libro::Registro.connection.quote(valor)} " \
      "WHERE id = #{registro.id}"
    )
  end

  def datos_alta(serie, **extra)
    { id_emisor: '89890001K', num_serie: serie, fecha_expedicion: Date.today,
      nombre_razon_emisor: 'Empresa SL', tipo_factura: 'F1',
      descripcion_operacion: 'Servicios',
      desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                             tipo_impositivo: BigDecimal('21'),
                             cuota_repercutida: BigDecimal('21.00'))],
      cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
      fecha_hora_gen: Time.now,
      destinatarios: [Destinatario.new(nombre_razon: 'Cliente SL', nif: '89890002E')] }
      .merge(extra)
  end

  # --- Encadenamiento -------------------------------------------------------

  def test_el_primer_registro_no_lleva_eslabon_anterior
    r = cadena.anotar_alta!(**datos_alta('FA/1'))

    assert_predicate r, :primero?
    assert_equal '', r.huella_anterior
    assert_match(/\A[0-9A-F]{64}\z/, r.huella)
  end

  def test_los_registros_se_encadenan_en_orden
    c = cadena
    uno = c.anotar_alta!(**datos_alta('FA/1'))
    dos = c.anotar_alta!(**datos_alta('FA/2'))
    tres = c.anotar_alta!(**datos_alta('FA/3'))

    assert_equal uno.huella, dos.huella_anterior
    assert_equal dos.huella, tres.huella_anterior
    assert_equal tres.id, c.reload.ultimo_registro_id
  end

  # La huella almacenada tiene que ser reproducible desde las columnas, sin
  # parsear el payload. Es lo que permite detectar una fila alterada.
  def test_la_huella_se_puede_recalcular_desde_las_columnas
    c = cadena
    c.anotar_alta!(**datos_alta('FA/1'))
    dos = c.anotar_alta!(**datos_alta('FA/2'))

    assert_predicate dos, :huella_cuadra?
    assert_equal dos.huella, dos.huella_recalculada
  end

  # Y la que viaja en el XML tiene que ser la misma que la guardada: si divergen,
  # la AEAT recalcula sobre el XML y no cuadra.
  def test_la_huella_guardada_es_la_que_viaja_en_el_payload
    r = cadena.anotar_alta!(**datos_alta('FA/1'))

    assert_includes r.payload, ">#{r.huella}<"
  end

  def test_el_qr_se_genera_al_anotar_sin_hablar_con_la_aeat
    r = cadena.anotar_alta!(**datos_alta('FA/1'))

    assert_includes r.qr_url, 'prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR'
    assert_includes r.qr_url, 'nif=89890001K'
    assert_includes r.qr_url, 'importe=121.00'
  end

  def test_una_anulacion_se_encadena_tras_el_alta
    c = cadena
    alta = c.anotar_alta!(**datos_alta('FA/1'))
    anulacion = c.anotar_anulacion!(id_emisor: '89890001K', num_serie: 'FA/1',
                                    fecha_expedicion: Date.today, fecha_hora_gen: Time.now)

    assert_equal 'anulacion', anulacion.tipo
    assert_equal alta.huella, anulacion.huella_anterior
    assert_predicate anulacion, :huella_cuadra?
  end

  # --- La restricción que impide bifurcar -----------------------------------

  # La AEAT acepta una cadena bifurcada sin avisar (comprobado contra el servicio
  # real), así que este índice es la única red que hay.
  def test_dos_registros_no_pueden_compartir_predecesor
    c = cadena
    uno = c.anotar_alta!(**datos_alta('FA/1'))
    c.anotar_alta!(**datos_alta('FA/2')) # este ya es el hijo legítimo de uno

    # Un segundo hijo del MISMO predecesor: eso es una bifurcación.
    assert_raises(ActiveRecord::RecordNotUnique) do
      c.registros.create!(tipo: 'alta', id_emisor: '89890001K', num_serie: 'FA/X',
                          fecha_expedicion: '07-08-2026', tipo_factura: 'F1',
                          cuota_total: '21.00', importe_total: '121.00',
                          huella: 'B' * 64, huella_anterior: uno.huella,
                          fecha_hora_gen: '2026-08-07T12:00:00+02:00',
                          payload: '<x/>', qr_url: '')
    end
  end

  def test_una_cadena_no_admite_dos_primeros_registros
    c = cadena
    c.anotar_alta!(**datos_alta('FA/1'))

    # huella_anterior = '' y no NULL justamente para que esto colisione: dos NULL
    # no chocan en un índice único, dos cadenas vacías sí.
    assert_raises(ActiveRecord::RecordNotUnique) do
      c.registros.create!(tipo: 'alta', id_emisor: '89890001K', num_serie: 'FA/Y',
                          fecha_expedicion: '07-08-2026', tipo_factura: 'F1',
                          cuota_total: '21.00', importe_total: '121.00',
                          huella: 'C' * 64, huella_anterior: '',
                          fecha_hora_gen: '2026-08-07T12:00:00+02:00',
                          payload: '<x/>', qr_url: '')
    end
  end

  # Cadenas distintas no se estorban: es la arquitectura de "un SIF virtual por
  # fuente", que evita el lock global.
  def test_dos_cadenas_distintas_tienen_cada_una_su_primer_registro
    a = cadena('INST-A')
    b = cadena('INST-B')
    ra = a.anotar_alta!(**datos_alta('A/1'))
    rb = b.anotar_alta!(**datos_alta('B/1'))

    assert_predicate ra, :primero?
    assert_predicate rb, :primero?
  end

  # --- Art. 7.i): autochequeo -----------------------------------------------

  def test_sin_anomalias_la_columna_queda_vacia
    c = cadena
    c.anotar_alta!(**datos_alta('FA/1'))
    dos = c.anotar_alta!(**datos_alta('FA/2'))

    assert_nil dos.anomalias
    refute_predicate dos, :anomalias?
  end

  # Se altera la fila a mano, saltándose attr_readonly con update_column, que es
  # justo lo que haría alguien manipulando la base de datos.
  def test_detecta_que_el_registro_anterior_fue_alterado
    c = cadena
    uno = c.anotar_alta!(**datos_alta('FA/1'))
    alterar!(uno, 'importe_total', '999.00')

    dos = c.anotar_alta!(**datos_alta('FA/2'))

    assert_includes dos.anomalias_lista, :huella_alterada
  end

  def test_detecta_que_el_eslabon_anterior_apunta_a_la_nada
    c = cadena
    c.anotar_alta!(**datos_alta('FA/1'))
    dos = c.anotar_alta!(**datos_alta('FA/2'))
    alterar!(dos, 'huella_anterior', 'F' * 64) # el predecesor ya no existe

    tres = c.anotar_alta!(**datos_alta('FA/3'))

    assert_includes tres.anomalias_lista, :encadenamiento_roto
  end

  # Lo esencial del art. 7.i: detectar NO puede parar la caja.
  def test_una_anomalia_no_impide_seguir_facturando
    c = cadena
    uno = c.anotar_alta!(**datos_alta('FA/1'))
    alterar!(uno, 'importe_total', '999.00')

    dos = c.anotar_alta!(**datos_alta('FA/2'))

    assert_predicate dos, :persisted?
    assert_predicate dos, :anomalias?
    assert_equal dos.id, c.reload.ultimo_registro_id
  end

  def test_avisa_de_las_anomalias_a_quien_se_configure
    avisos = []
    Libro.configure { |cfg| cfg.al_detectar_anomalia = ->(a, r) { avisos << [a, r.num_serie] } }
    c = cadena
    uno = c.anotar_alta!(**datos_alta('FA/1'))
    alterar!(uno, 'importe_total', '999.00')
    c.anotar_alta!(**datos_alta('FA/2'))

    assert_equal [[[:huella_alterada], 'FA/2']], avisos
  ensure
    Libro.configure { |cfg| cfg.al_detectar_anomalia = nil }
  end

  # El sentido de la comprobación del reloj es el que confunde: que pase mucho
  # tiempo entre registros es lo NORMAL y no es anomalía.
  def test_que_pase_mucho_tiempo_entre_registros_no_es_anomalia
    c = cadena
    c.anotar_alta!(**datos_alta('FA/1', fecha_hora_gen: Time.now - 86_400))
    dos = c.anotar_alta!(**datos_alta('FA/2'))

    refute_includes dos.anomalias_lista, :reloj_hacia_atras
  end

  def test_detecta_que_el_reloj_fue_hacia_atras
    c = cadena
    c.anotar_alta!(**datos_alta('FA/1', fecha_hora_gen: Time.now + 3600))
    dos = c.anotar_alta!(**datos_alta('FA/2'))

    assert_includes dos.anomalias_lista, :reloj_hacia_atras
  end

  # --- El número de instalación no se genera solo --------------------------

  def test_abrir_una_cadena_exige_numero_de_instalacion
    error = assert_raises(ValidacionError) do
      Libro::Cadena.abrir!(numero_instalacion: '  ', nif_obligado: '89890001K',
                           nombre_obligado: 'Empresa SL')
    end

    assert_match(/no se genera solo/, error.message)
  end

  def test_el_numero_de_instalacion_no_se_puede_repetir
    cadena('INST-REPE')

    assert_raises(ActiveRecord::RecordNotUnique) { cadena('INST-REPE') }
  end
end
