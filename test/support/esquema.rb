# frozen_string_literal: true

ESQUEMAS = File.expand_path('../../lib/verifactu_rails/schemas', __dir__)

# Antes de cargar nokogiri: libxml2 lee esta variable al inicializar el catálogo,
# que es lo que resuelve el import remoto a xmldsig sin salir a la red.
# La pone el proceso de tests, nunca la librería (ver schemas/PROCEDENCIA.md).
ENV['XML_CATALOG_FILES'] ||= File.join(ESQUEMAS, 'catalog.xml')

require 'nokogiri'

module Esquema
  module_function

  # Compilar el XSD cuesta ~40 ms; se cachea porque lo usan muchos tests.
  def suministro_lr
    @suministro_lr ||= compilar('SuministroLR.xsd')
  end

  def compilar(fichero)
    ruta = File.join(ESQUEMAS, fichero)
    # Con la ruta como URL base: sin ella los imports relativos del XSD se
    # buscarían en el directorio de trabajo.
    Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(ruta), ruta))
  end

  def errores(xml)
    suministro_lr.validate(Nokogiri::XML(xml))
  end
end
