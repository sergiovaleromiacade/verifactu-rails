# frozen_string_literal: true

# Base de datos para los tests del libro registro.
#
# NO se salta si no la encuentra: aborta. Esto es una gema para Rails, y en Rails
# siempre hay base de datos. Un `skip` convertiría veintitantos tests -entre ellos
# los que demuestran que la cadena no se puede bifurcar- en cobertura fantasma:
# desaparecerían en silencio en cualquier entorno mal configurado, que es
# exactamente donde más falta hacen.
#
# Se usa, por este orden:
#   1. La conexión que ya haya establecida (una app Rails, un initializer).
#   2. VF_DATABASE_URL o DATABASE_URL.
#   3. PostgreSQL local en verifactu_rails_test.
module BaseDatos
  # El pool tiene que dar para los hilos del test de concurrencia; si no, se
  # serializan esperando conexión y ese test no probaría nada.
  RESPALDO = 'postgresql://localhost/verifactu_rails_test?pool=16'

  module_function

  def url = ENV['VF_DATABASE_URL'] || ENV['DATABASE_URL'] || RESPALDO

  # Una base de datos que no se llame "de tests" no se toca. La suite tira las
  # tablas y las vuelve a crear, y `limpiar!` vacía cadenas y registros en cada
  # setup: correrla contra la base equivocada no es un riesgo teórico, ya se
  # llevó por delante el libro local de la campaña del 07-08-2026 contra
  # preproducción (ver doc/FUENTES.md). Los registros seguían en la AEAT, pero el
  # lado local con el que contrastarlos dejó de existir.
  PATRON_DE_TESTS = /test/i

  def preparar!
    return true if @preparada

    require 'active_record'
    conectar!
    exigir_base_de_datos_de_tests!
    require_relative '../../lib/verifactu_rails/libro'
    migrar!
    @preparada = true
  end

  # Se mira el nombre de la conexión REAL, no el de `url`: si quien ejecuta los
  # tests ya tenía una conexión establecida, es esa la que se va a vaciar.
  def nombre_de_la_base
    ActiveRecord::Base.connection_db_config.database.to_s
  end

  def exigir_base_de_datos_de_tests!
    nombre = nombre_de_la_base
    return if nombre.match?(PATRON_DE_TESTS)
    return if ENV['VF_BD_BORRABLE'] == '1'

    abort(<<~TXT)

      La base de datos #{nombre.inspect} no parece de tests, y la suite la borraría.

      Antes de cada test se vacían las tablas del libro, y al empezar se tiran y
      se recrean. Si aquí hay registros de una prueba real contra la AEAT, los
      pierdes: en la AEAT seguirán anotados, pero el libro local con el que
      contrastarlos no volverá.

      Para arreglarlo, una de dos:

        VF_DATABASE_URL=postgresql://localhost/verifactu_rails_test bundle exec rake test

      O, si de verdad esta base es desechable y sabes lo que haces:

        VF_BD_BORRABLE=1 bundle exec rake test

    TXT
  end

  def conectar!
    establecer_conexion_si_falta
    ActiveRecord::Base.connection.execute('select 1')
  rescue StandardError => e
    abort(ayuda(e))
  end

  # Si quien ejecuta los tests ya tiene una conexión configurada, se respeta: es
  # su base de datos, no la nuestra.
  def establecer_conexion_si_falta
    ActiveRecord::Base.connection_db_config
  rescue StandardError
    ActiveRecord::Base.establish_connection(url)
  end

  def migrar!
    silenciar do
      begin
        VerifactuRails::Libro::Migracion.new.migrate(:down)
      rescue StandardError
        nil # la primera vez no hay nada que tirar
      end
      VerifactuRails::Libro::Migracion.new.migrate(:up)
    end
  end

  def limpiar!
    VerifactuRails::Libro::Cadena.update_all(ultimo_registro_id: nil)
    VerifactuRails::Libro::Registro.delete_all
    VerifactuRails::Libro::Cadena.delete_all
  end

  def silenciar
    anterior = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    yield
  ensure
    ActiveRecord::Migration.verbose = anterior
  end

  def ayuda(error)
    <<~TXT

      No se pudo conectar a la base de datos de tests.

        Intentado: #{url}
        Error:     #{error.class}: #{error.message.lines.first&.strip}

      Los tests del libro registro necesitan una base de datos de verdad: hay que
      demostrar que un índice único impide bifurcar la cadena y que el lock
      serializa, y eso no se puede simular con dobles.

      Para arreglarlo, una de dos:

        createdb verifactu_rails_test
        VF_DATABASE_URL=postgresql://usuario@host/otra_bd bundle exec rake test

    TXT
  end
end
