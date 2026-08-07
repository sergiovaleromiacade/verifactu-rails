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

  def preparar!
    return true if @preparada

    require 'active_record'
    conectar!
    require_relative '../../lib/verifactu_rails/libro'
    migrar!
    @preparada = true
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
