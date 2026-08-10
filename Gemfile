# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 13.0'

  # Solo para probar el generador (`rails g verifactu:install`). NO es
  # dependencia de la gema: verifactu-rails se instala en una app Rails, que ya
  # trae railties, y fuera de Rails el núcleo funciona sin nada de esto.
  gem 'railties', '>= 7.0', '< 9'
end

# activerecord NO va aquí: es dependencia de ejecución y la declara el gemspec,
# porque la capa Libro no funciona sin él. El adaptador sí es cosa del entorno:
# la gema no debe imponer PostgreSQL ni MySQL, solo los tests eligen uno.
group :development, :test do
  gem 'pg', '~> 1.5'
end
