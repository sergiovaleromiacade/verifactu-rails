# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module Verifactu
  module Generators
    # `rails g verifactu:install`
    #
    # Deja dos ficheros y nada más: la migración del libro registro y un
    # initializer con la identificación del SIF.
    #
    # Lo que este generador NO hace, y es deliberado:
    #
    #   - No abre ninguna cadena. El NumeroInstalacion no se autogenera en
    #     ninguna parte de esta gema (ver Cadena.abrir!): un contenedor que se
    #     recrea en cada despliegue acabaría con una instalación por despliegue,
    #     y eso vacía de sentido el encadenamiento.
    #   - No toca el certificado ni escribe dónde vive. Certificado recibe los
    #     bytes ya cargados y no sabe leer ficheros ni ENV a propósito: la
    #     política de almacenamiento de la credencial es de quien despliega.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Instala el libro registro VERI*FACTU: migración e initializer.'

      def crear_initializer
        template 'verifactu.rb.tt', 'config/initializers/verifactu.rb'
      end

      def crear_migracion
        migration_template 'instalar_verifactu.rb.tt',
                           'db/migrate/instalar_verifactu.rb'
      end

      def siguientes_pasos
        say <<~TXT

          Instalado. Quedan dos cosas, y ninguna se puede hacer por ti:

            1. Edita config/initializers/verifactu.rb. Los valores que trae son
               inválidos a propósito, para que falle pronto y no mande a la AEAT
               una identificación de SIF inventada.
            2. rails db:migrate

          Después, abre una cadena por cada fuente de facturación (una por
          tienda, TPV o sede: son SIF virtuales distintos). En un seed, en una
          tarea rake o en la consola, NO en el initializer: una cadena es un
          dato, se abre una vez y a conciencia.

            VerifactuRails::Libro::Cadena.abrir!(
              numero_instalacion: 'TIENDA-VALENCIA-20260810120000',
              nif_obligado: '...', nombre_obligado: '...')

        TXT
      end
    end
  end
end
