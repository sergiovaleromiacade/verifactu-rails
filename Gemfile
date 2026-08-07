# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 13.0'
end

# Solo para la capa Rails (lib/verifactu_rails/libro) y sus tests. El núcleo no
# depende de Rails: la gema no declara esto como dependencia de ejecución.
group :development, :test do
  gem 'activerecord', '~> 7.0'
  gem 'pg', '~> 1.5'
end
