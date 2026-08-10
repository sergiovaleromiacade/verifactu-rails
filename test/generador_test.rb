# frozen_string_literal: true

require 'minitest/autorun'
require 'rails/generators'
require 'rails/generators/test_case'
require_relative '../lib/verifactu-rails'
require_relative '../lib/generators/verifactu/install/install_generator'

# Lo que genera el generador lleva acentos, porque el proyecto está en español, y
# `assert_file` lo lee con la codificación externa por defecto: en una shell sin
# LANG eso es US-ASCII y revienta al leer. El código generado está bien -Ruby lee
# el fuente como UTF-8 pase lo que pase con el locale-, así que lo que hay que
# arreglar es el test, no dejar que pase o falle según quién lo ejecute.
Encoding.default_external = Encoding::UTF_8

# `rails g verifactu:install`.
#
# Se prueba en un destino de usar y tirar, como cualquier generador. Lo que hay
# que demostrar aquí no es que escriba ficheros, sino tres cosas concretas que,
# si se rompen, se rompen en silencio y lejos: que la migración hereda el
# esquema en vez de copiarlo, que los valores de relleno del initializer no
# pueden llegar a la AEAT, y que las plantillas viajan dentro de la gema.
class GeneradorTest < Rails::Generators::TestCase
  tests Verifactu::Generators::InstallGenerator
  destination File.expand_path('../tmp/generador', __dir__)
  setup :prepare_destination

  RAIZ = File.expand_path('..', __dir__)

  def test_deja_migracion_e_initializer
    run_generator

    assert_file 'config/initializers/verifactu.rb'
    assert_migration 'db/migrate/instalar_verifactu.rb'
  end

  # El esquema NO se copia a la app: se hereda. Si alguien "mejora" esto
  # volcando los create_table en la plantilla, lo que ejercitan los tests de la
  # gema deja de ser lo que se instala, y la divergencia no la nota nadie hasta
  # que falta un índice único en producción.
  def test_la_migracion_hereda_el_esquema_en_vez_de_copiarlo
    run_generator

    assert_migration 'db/migrate/instalar_verifactu.rb' do |contenido|
      assert_match(/class InstalarVerifactu < VerifactuRails::Libro::Migracion/,
                   contenido)
      refute_match(/create_table/, contenido)
    end
  end

  # El initializer se genera con valores inválidos a propósito. La prueba de que
  # eso sirve de algo no es que ponga "CAMBIAME", es que con esos valores no se
  # pueda construir un SistemaInformatico.
  def test_los_valores_de_relleno_no_pueden_llegar_a_la_aeat
    run_generator

    assert_file 'config/initializers/verifactu.rb', /CAMBIAME/

    error = assert_raises(VerifactuRails::ValidacionError) do
      VerifactuRails::SistemaInformatico.new(
        nombre_razon: 'CAMBIAME: razón social del productor', nif: 'CAMBIAME',
        nombre_sistema: 'CAMBIAME', id_sistema: 'CAMBIAME', version: 'CAMBIAME',
        numero_instalacion: 'INST-1'
      )
    end
    assert_match(/NIF/i, error.message)
  end

  # Las plantillas van en .tt para que Rails no las tome por código, y por eso
  # NO las recoge el 'lib/**/*.rb' del gemspec. Sin la línea que las incluye, el
  # generador funciona desde el repo -donde los ficheros están- y falla al
  # instalarse desde la gema. Este test es la única forma de verlo sin publicar.
  def test_las_plantillas_viajan_dentro_de_la_gema
    spec = Gem::Specification.load(File.join(RAIZ, 'verifactu-rails.gemspec'))
    plantillas = Dir[File.join(RAIZ, 'lib/generators/**/*.tt')]
                 .map { |ruta| ruta.delete_prefix("#{RAIZ}/") }

    refute_empty plantillas, 'no se encontró ninguna plantilla .tt'
    plantillas.each { |plantilla| assert_includes spec.files, plantilla }
  end
end
