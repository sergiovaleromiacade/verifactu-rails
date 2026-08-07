# frozen_string_literal: true

require_relative 'support/base_datos'
require 'minitest/autorun'
require_relative '../lib/verifactu-rails'

# El hallazgo que motiva todo esto: la AEAT acepta una cadena bifurcada SIN
# avisar (comprobado contra el servicio real). No hay red por ese lado, así que
# la integridad de la cadena tiene que sostenerla la base de datos.
#
# Estos tests usan hilos de verdad contra PostgreSQL de verdad. Un doble no
# serviría: lo que se está probando es precisamente el comportamiento del motor
# ante escrituras simultáneas.
class ConcurrenciaTest < Minitest::Test
  include VerifactuRails

  HILOS = 8

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
    @cadena = Libro::Cadena.abrir!(numero_instalacion: "CONC-#{SecureRandom.hex(4)}",
                                   nif_obligado: '89890001K', nombre_obligado: 'Empresa SL')
  end

  def datos_alta(serie)
    { id_emisor: '89890001K', num_serie: serie, fecha_expedicion: Date.today,
      nombre_razon_emisor: 'Empresa SL', tipo_factura: 'F1',
      descripcion_operacion: 'Servicios',
      desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                             tipo_impositivo: BigDecimal('21'),
                             cuota_repercutida: BigDecimal('21.00'))],
      cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
      fecha_hora_gen: Time.now,
      destinatarios: [Destinatario.new(nombre_razon: 'Cliente SL', nif: '89890002E')] }
  end

  # Lanza HILOS a la vez sobre la misma cadena, cada uno con su propia instancia
  # cargada de la base de datos, que es como se comportan dos peticiones Rails.
  # La barrera hace que salgan todos juntos y no en fila.
  def embestir(sin_lock: false)
    barrera = Queue.new
    resultados = Queue.new

    hilos = Array.new(HILOS) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          c = Libro::Cadena.find(@cadena.id)
          # Anula el lock solo en esta instancia. Escrito con el `if` fuera a
          # propósito: `def c.with_lock(*) = yield if sin_lock` se parsea como
          # "define el método si sin_lock", que es lo que se quiere, pero se lee
          # como "el cuerpo es yield if sin_lock", que sería un NameError.
          if sin_lock
            def c.with_lock(*) = yield
          end
          barrera.pop
          begin
            resultados << [:ok, c.anotar_alta!(**datos_alta("FA/#{i}")).id]
          rescue StandardError => e
            resultados << [:error, e.class]
          end
        end
      end
    end

    HILOS.times { barrera << :ya }
    hilos.each(&:join)
    Array.new(HILOS) { resultados.pop }
  end

  # La invariante que importa, y la única que la AEAT no comprueba: ningún
  # registro puede compartir predecesor con otro.
  def assert_cadena_sin_bifurcar
    por_predecesor = @cadena.registros.group(:huella_anterior).count
    bifurcados = por_predecesor.select { |_, n| n > 1 }

    assert_empty bifurcados, "La cadena se bifurcó: #{bifurcados.inspect}"
    assert_equal 1, por_predecesor.fetch('', 0), 'Debe haber exactamente un PrimerRegistro'
  end

  def test_ocho_hilos_a_la_vez_producen_una_cadena_lineal
    resultados = embestir

    assert_equal HILOS, resultados.count { |estado, _| estado == :ok },
                 "Con el lock no debería fallar ninguno: #{resultados.inspect}"
    assert_equal HILOS, @cadena.registros.count
    assert_cadena_sin_bifurcar
  end

  # Se recorre la cadena desde el primero: si es lineal, se llega a todos.
  def test_la_cadena_resultante_se_puede_recorrer_entera
    embestir

    visitados = []
    actual = @cadena.registros.find_by(huella_anterior: '')
    while actual
      visitados << actual.num_serie
      actual = @cadena.registros.find_by(huella_anterior: actual.huella)
    end

    assert_equal HILOS, visitados.size, "La cadena se cortó: #{visitados.inspect}"
    assert_equal @cadena.registros.count, visitados.uniq.size
  end

  # EL test importante. Sin el lock, varios hilos leen el mismo "último registro"
  # y quieren encadenar detrás de él. Sin el índice único eso produciría una
  # cadena bifurcada que la AEAT aceptaría en silencio; con él, el segundo choca.
  #
  # No se afirma cuántos fallan -depende del planificador-, solo que NINGUNO
  # consigue bifurcar. Esa es la garantía.
  def test_sin_lock_el_indice_impide_bifurcar_igualmente
    resultados = embestir(sin_lock: true)
    errores = resultados.select { |estado, _| estado == :error }.map(&:last)

    assert_cadena_sin_bifurcar

    # Se afirma QUÉ error, no solo que hubo alguno: si los fallos fueran un
    # NameError del propio stub, el test pasaría sin probar nada del índice.
    assert_equal [ActiveRecord::RecordNotUnique], errores.uniq,
                 "Los fallos deben ser colisiones del índice: #{errores.inspect}"
    refute_empty errores,
                 'Sin lock se esperaba al menos una colisión; si no la hubo, el ' \
                 'test no está probando lo que dice probar'
    assert_equal HILOS - errores.size, @cadena.registros.count
  end
end
