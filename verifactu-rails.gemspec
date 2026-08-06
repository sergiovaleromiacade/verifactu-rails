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
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  spec.metadata['rubygems_mfa_required'] = 'true'

  # Sin dependencias de runtime todavía, y es deliberado: no se declara una gema
  # hasta que lib/ la usa de verdad. nokogiri llegará con el generador de XML y
  # rqrcode con el QR de cotejo.
end
