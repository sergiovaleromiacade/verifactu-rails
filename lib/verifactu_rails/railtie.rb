# frozen_string_literal: true

module VerifactuRails
  # Enganche con Rails. Se carga SOLO si Rails está delante (ver el final de
  # lib/verifactu-rails.rb): el núcleo -huella, XML, transporte- no depende de
  # Rails y no debe empezar a depender por esto.
  #
  # Hace una sola cosa: cargar la capa Libro cuando ActiveRecord esté listo.
  #
  # Fuera de Rails esa capa es opt-in a propósito (`require
  # 'verifactu_rails/libro'`), porque exige ActiveRecord y quien solo quiera
  # calcular huellas no tiene por qué arrastrarlo. Dentro de Rails ActiveRecord
  # está siempre, así que mantener el require manual solo conseguiría que
  # `Cadena` no existiera hasta que alguien se acordara de escribirlo.
  #
  # Va por `on_load(:active_record)` y no por un require directo porque
  # libro.rb declara modelos, y declarar un modelo fuerza la carga de
  # ActiveRecord::Base. Hacerlo en el arranque le quita a la app la carga
  # diferida para todo el resto.
  #
  # Los generadores NO se registran aquí: Rails los descubre solo buscando
  # lib/generators/**/*_generator.rb por el $LOAD_PATH.
  class Railtie < ::Rails::Railtie
    initializer 'verifactu.libro' do
      ActiveSupport.on_load(:active_record) do
        require 'verifactu_rails/libro'
      end
    end
  end
end
