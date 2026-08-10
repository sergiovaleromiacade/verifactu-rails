# frozen_string_literal: true

require_relative 'lib/verifactu_rails/version'

Gem::Specification.new do |spec|
  spec.name     = 'verifactu-rails'
  spec.version  = VerifactuRails::VERSION
  spec.authors  = ['Sergio Valero']
  spec.email    = ['sergiovalero@miacade.es']

  spec.summary  = 'Integración con VERI*FACTU (AEAT) para Ruby y Rails'
  spec.description = <<~TXT
    Componente para generar y remitir registros de facturación VERI*FACTU a la
    AEAT: cálculo de la huella encadenada, formateo canónico de importes y
    transporte con autenticación mutua TLS. Solo modalidad VERI*FACTU.
    Es una librería, no un sistema de facturación llave en mano.
  TXT

  spec.license = 'MIT'

  # >= 3.0 por la sintaxis de método endless usada en Transporte.
  spec.required_ruby_version = '>= 3.0'

  spec.files = Dir[
    'lib/**/*.rb',
    # El catálogo va con los XSD: sin él no compilan (import remoto a xmldsig).
    'lib/verifactu_rails/schemas/*.xsd',
    'lib/verifactu_rails/schemas/catalog.xml',
    'lib/verifactu_rails/schemas/PROCEDENCIA.md',
    # Las plantillas del generador NO entran por 'lib/**/*.rb': van en .tt justo
    # para que Rails no las confunda con código. Sin esta línea, `rails g
    # verifactu:install` funciona desde el repo y falla instalado desde la gema,
    # que es el fallo más difícil de ver venir.
    'lib/generators/**/*.tt',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  spec.metadata['rubygems_mfa_required'] = 'true'

  # Rango, no pin: fijar nokogiri a una versión exacta es justo lo que deja
  # ininstalable a verifactu-rb en Rails moderno.
  spec.add_dependency 'nokogiri', '~> 1.15'

  # Lo usa la capa de persistencia (lib/verifactu_rails/libro): los modelos, la
  # migración y el SELECT ... FOR UPDATE que serializa el encadenamiento. El
  # núcleo -huella, XML, transporte, consulta, QR- no lo necesita.
  #
  # Rango ANCHO a propósito: en una app Rails ActiveRecord ya está, así que esto
  # solo sirve para que Bundler compruebe la versión. Un `~> 7.0` se plantaría
  # ante una app con Rails 8 sin motivo real, que es el mismo error que deja
  # ininstalables a otras gemas del ramo.
  spec.add_dependency 'activerecord', '>= 7.0', '< 9'

  # rqrcode entrará con el QR de cotejo. No se declara hasta que lib/ la use.
end
