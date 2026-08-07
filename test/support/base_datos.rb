# frozen_string_literal: true

# Los tests del libro registro necesitan una base de datos DE VERDAD: hay que
# demostrar que un índice único impide bifurcar la cadena y que el lock serializa,
# y eso no se puede simular con dobles.
#
# Se usa PostgreSQL por defecto. Si no hay ninguna accesible, los tests del libro
# se saltan en vez de fallar: que alguien sin Postgres no pueda correr el resto de
# la suite sería peor.
module BaseDatos
  # El pool tiene que dar para los hilos del test de concurrencia; si no, los
  # hilos se serializan esperando conexión y el test no probaría nada.
  URL = ENV['VF_DATABASE_URL'] || 'postgresql://localhost/verifactu_rails_test?pool=16'

  module_function

  def disponible?
    return @disponible unless @disponible.nil?

    @disponible = begin
      require 'active_record'
      ActiveRecord::Base.establish_connection(URL)
      ActiveRecord::Base.connection.execute('select 1')
      true
    rescue StandardError => e
      @motivo = e.message
      false
    end
  end

  def motivo = @motivo

  def preparar!
    return false unless disponible?
    return true if @preparada

    require_relative '../../lib/verifactu_rails/libro'
    silenciar do
      VerifactuRails::Libro::Migracion.new.migrate(:down)
    rescue StandardError
      nil # la primera vez no hay nada que tirar
    end
    silenciar { VerifactuRails::Libro::Migracion.new.migrate(:up) }
    @preparada = true
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
end
