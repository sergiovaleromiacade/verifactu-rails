# frozen_string_literal: true

require 'minitest/autorun'
require 'rubygems'

# Lo que se publica tiene que estar completo.
#
# Este fallo no se ve desde el repo, que es lo que lo hace peligroso: en local
# todos los ficheros están, así que los enlaces funcionan y los tests pasan. Solo
# se rompe una vez publicada la gema, y lo descubre quien la evalúa —justo la
# persona a la que menos le apetece encontrarse un 404 en el documento que
# delimita responsabilidades—.
#
# Las plantillas del generador se comprueban aparte, en generador_test.rb, que es
# donde vive lo del generador.
class EmpaquetadoTest < Minitest::Test
  RAIZ = File.expand_path('..', __dir__)

  # Enlaces markdown que apuntan a un fichero del repo: ni http(s), ni mailto,
  # ni anclas.
  PATRON_ENLACE = /\]\((?!https?:|mailto:|#)([^)]+)\)/

  def spec
    @spec ||= Gem::Specification.load(File.join(RAIZ, 'verifactu-rails.gemspec'))
  end

  def test_los_documentos_que_se_publican_no_enlazan_a_ficheros_que_no_viajan
    documentos = spec.files.grep(/\.md\z/)

    refute_empty documentos, 'el gemspec no empaqueta ningún documento'

    rotos = documentos.flat_map do |documento|
      enlaces(documento)
        .reject { |destino| spec.files.include?(resolver(destino, documento)) }
        .map { |destino| "#{documento} -> #{destino}" }
    end

    assert_empty rotos,
                 "Enlaces a ficheros que no se empaquetan; en la gema publicada " \
                 "quedarían rotos: #{rotos.join(', ')}"
  end

  private

  # Un enlace es relativo al documento que lo contiene, no a la raíz: desde
  # doc/FUENTES.md, "../COMPLIANCE.md" es el COMPLIANCE.md de la raíz. Comparar
  # la cadena tal cual daba un falso positivo justo en el caso que más importa,
  # que es el enlace que cruza de directorio.
  def resolver(destino, documento)
    File.expand_path(destino, File.join('/', File.dirname(documento)))
        .delete_prefix('/')
  end

  def enlaces(documento)
    File.read(File.join(RAIZ, documento), encoding: 'UTF-8')
        .scan(PATRON_ENLACE)
        .flatten
        .map { |destino| destino.sub(/:\d+\z/, '') } # admite fichero.rb:42
        .uniq
  end
end
