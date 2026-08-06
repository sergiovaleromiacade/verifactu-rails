# frozen_string_literal: true

# Guarda los XSD oficiales de la AEAT.
#
# Dos cometidos distintos:
#   1. Detectar que alguien los ha editado localmente. Son el contrato: se
#      actualizan volviendo a descargarlos, nunca a mano.
#   2. Fijar las suposiciones del esquema sobre las que descansa el alcance del
#      proyecto. Si la AEAT cambia alguna, queremos enterarnos aquí y no en
#      producción.

require_relative 'support/esquema'
require 'minitest/autorun'
require 'digest'

class EsquemasTest < Minitest::Test
  # Descargados de prewww2.aeat.es el 06-08-2026.
  HUELLAS = {
    'SuministroInformacion.xsd' => 'ee4c1655175644de44c4c25055ffeb8e5f4bb4bc3834ce8254d4222ef18c8aa1',
    'SuministroLR.xsd' => 'cbdac8d427cc5ab5d77ca48974cab0f35d6bb819c4c66db361681e3710aeba36',
    'RespuestaSuministro.xsd' => '82acf80f785643caac13087aae66808ed721a13f08ca5218cf8ae81b695549ef',
    'ConsultaLR.xsd' => 'bf2cdb8fc4b95b291757a72b76d8fffca06a6d30d9329122ca2fd6b2d5f8f1b1',
    'RespuestaConsultaLR.xsd' => 'de35063acb8d9ba0d6ae51acc6b595de9c2b12333250e95e13108ef5f2670d45',
    'EventosSIF.xsd' => 'cc7347c6a9a57a0c8edbc6b9ddcce55176452d0db0e68369477e207e9fbdd7e7',
    'RespuestaValRegistNoVeriFactu.xsd' => '8f47af4f3c49d29b6a62aed261c09f171e855ad6d6bb72ef3fc0b147dc9572f0',
    'xmldsig-core-schema.xsd' => 'd102ad3df7664c307e0c2c776ba4a90513b1969974d8a940bae1a77f9f21e15d'
  }.freeze

  # EventosSIF y RespuestaValRegistNoVeriFactu quedan fuera: son de NO VERI*FACTU.
  EN_ALCANCE = %w[
    SuministroLR.xsd RespuestaSuministro.xsd
    ConsultaLR.xsd RespuestaConsultaLR.xsd
  ].freeze

  SF = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/dep/' \
       'aplicaciones/es/aeat/tike/cont/ws/SuministroInformacion.xsd'

  def test_los_esquemas_no_han_sido_editados
    HUELLAS.each do |fichero, esperada|
      ruta = File.join(ESQUEMAS, fichero)
      assert File.exist?(ruta), "Falta #{fichero}"
      assert_equal esperada, Digest::SHA256.file(ruta).hexdigest,
                   "#{fichero} ha cambiado. Si es una actualización de la AEAT, " \
                   'actualiza la huella en este test en el mismo commit.'
    end
  end

  # Compilar es la prueba real de que el catálogo resuelve el import remoto:
  # sin él libxml2 aborta con "Attempt to load network entity".
  #
  # El XSD se carga como documento CON su ruta, no como String suelto: los
  # imports relativos (SuministroInformacion.xsd) se resuelven contra la URL base
  # del documento, y sin ella libxml2 los busca en el directorio de trabajo.
  def test_los_esquemas_en_alcance_compilan_sin_red
    EN_ALCANCE.each do |fichero|
      assert_empty Esquema.compilar(fichero).errors, "#{fichero} no compila"
    rescue Nokogiri::XML::SyntaxError => e
      flunk "#{fichero} no compila: #{e.message}"
    end
  end

  # El alcance del proyecto (solo VERI*FACTU, sin XAdES) depende de que la firma
  # sea opcional. Si dejara de serlo, habría que replantear el proyecto entero.
  def test_la_firma_sigue_siendo_opcional
    doc = Nokogiri::XML(File.read(File.join(ESQUEMAS, 'SuministroInformacion.xsd')))
    firmas = doc.xpath('//xs:element[@ref="ds:Signature"]',
                       'xs' => 'http://www.w3.org/2001/XMLSchema')

    refute_empty firmas, 'No aparece ds:Signature en el esquema'
    firmas.each do |firma|
      assert_equal '0', firma['minOccurs'],
                   'ds:Signature ha pasado a ser obligatoria: el alcance ' \
                   '"solo VERI*FACTU sin XAdES" ya no se sostiene'
    end
  end

  # El tamaño de lote no es folclore: está en el esquema y la cola debe respetarlo.
  def test_el_lote_sigue_siendo_de_1000_registros
    doc = Nokogiri::XML(File.read(File.join(ESQUEMAS, 'SuministroLR.xsd')))
    registro = doc.at_xpath('//xs:element[@name="RegistroFactura"]',
                            'xs' => 'http://www.w3.org/2001/XMLSchema')

    assert_equal '1000', registro['maxOccurs']
  end
end
