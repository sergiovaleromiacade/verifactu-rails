# frozen_string_literal: true

require 'nokogiri'
require_relative 'formato'
require_relative 'registro'

module VerifactuRails
  # Documento RegFactuSistemaFacturacion: la cabecera con el obligado tributario
  # más un lote de registros de facturación.
  #
  # El encadenamiento es estrictamente serial y esta clase NO lo gestiona: recibe
  # los registros ya emparejados con su registro anterior. Decidir cuál es el
  # anterior exige un lock por NIF+serie en la base de datos, y eso pertenece a la
  # capa de integración, no a un generador de XML.
  class Envio
    MAXIMO_REGISTROS = 1000 # maxOccurs de RegistroFactura en el esquema

    attr_reader :nif_obligado, :nombre_obligado, :entradas

    # @param entradas [Array<Array(registro, anterior)>] cada registro con el
    #   RegistroAnterior que le precede en la cadena (nil solo en el primero).
    def initialize(nif_obligado:, nombre_obligado:, entradas:)
      @nif_obligado = Formato.nif(nif_obligado, 'NIF del obligado')
      @nombre_obligado = Formato.limitar(nombre_obligado, 'NombreRazon del obligado', 120)
      @entradas = entradas

      raise ArgumentError, 'El envío necesita al menos un registro' if entradas.empty?

      if entradas.size > MAXIMO_REGISTROS
        raise ArgumentError,
              "Un envío admite como mucho #{MAXIMO_REGISTROS} registros " \
              "(recibidos #{entradas.size}). Parte el lote."
      end
    end

    def to_xml
      constructor = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml['sum'].RegFactuSistemaFacturacion('xmlns:sum' => NS_LR, 'xmlns:sf' => NS_SF) do
          xml['sum'].Cabecera do
            xml['sf'].ObligadoEmision do
              xml['sf'].NombreRazon nombre_obligado
              xml['sf'].NIF nif_obligado
            end
          end
          entradas.each do |registro, anterior|
            xml['sum'].RegistroFactura do
              registro.construir(xml, anterior: anterior)
            end
          end
        end
      end
      constructor.to_xml
    end
  end
end
