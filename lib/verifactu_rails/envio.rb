# frozen_string_literal: true

require 'nokogiri'
require_relative 'formato'
require_relative 'registro'
require_relative 'error'

module VerifactuRails
  # Documento RegFactuSistemaFacturacion: la cabecera con el obligado tributario
  # más un lote de registros de facturación.
  #
  # El encadenamiento es estrictamente serial y esta clase NO lo gestiona: recibe
  # los registros ya emparejados con su registro anterior. Decidir cuál es el
  # anterior exige un lock por SIF+NIF en la base de datos, y eso pertenece a la
  # capa de integración, no a un generador de XML.
  class Envio
    MAXIMO_REGISTROS = 1000 # maxOccurs de RegistroFactura en el esquema

    attr_reader :nif_obligado, :nombre_obligado, :entradas

    # @param entradas [Array<Array(registro, anterior)>] cada registro con el
    #   RegistroAnterior que le precede en la cadena (nil solo en el primero).
    def initialize(nif_obligado:, nombre_obligado:, entradas:)
      @nif_obligado = Formato.nif(nif_obligado, 'NIF del obligado')
      @nombre_obligado = Formato.limitar(nombre_obligado, 'NombreRazon del obligado', 120)
      @entradas = normalizar(entradas)

      raise ValidacionError, 'El envío necesita al menos un registro' if @entradas.empty?

      if entradas.size > MAXIMO_REGISTROS
        raise ValidacionError,
              "Un envío admite como mucho #{MAXIMO_REGISTROS} registros " \
              "(recibidos #{entradas.size}). Parte el lote."
      end

      validar_emisores!
    end

    def to_xml
      constructor = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml['sum'].RegFactuSistemaFacturacion('xmlns:sum' => NS_LR, 'xmlns:sum1' => NS_SF) do
          xml['sum'].Cabecera do
            xml['sum1'].ObligadoEmision do
              xml['sum1'].NombreRazon nombre_obligado
              xml['sum1'].NIF nif_obligado
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

    private

    # `entradas` es una lista de pares [registro, anterior]. Sin comprobarla:
    #   - [[alta]] desestructura con anterior=nil y el registro sale como
    #     PrimerRegistro="S" en silencio, que es un error admisible en la AEAT si
    #     ya hay registros de ese SIF.
    #   - una anulación con anterior=nil se construía y solo fallaba al
    #     serializar, pese a que RegistroAnulacion dice explícitamente que quiere
    #     fallar antes. El sitio donde se conoce el anterior es este.
    def normalizar(entradas)
      unless entradas.is_a?(Array)
        raise ValidacionError, "entradas debe ser un array de pares [registro, anterior] " \
                               "(recibido: #{entradas.class})"
      end

      entradas.each_with_index.map do |entrada, i|
        unless entrada.is_a?(Array) && entrada.size == 2
          raise ValidacionError,
                "entradas[#{i}] debe ser un par [registro, anterior]; para el primero " \
                'de la cadena, [registro, nil]'
        end

        registro, anterior = entrada
        unless registro.is_a?(RegistroAlta) || registro.is_a?(RegistroAnulacion)
          raise ValidacionError,
                "entradas[#{i}] debe llevar un RegistroAlta o RegistroAnulacion " \
                "(recibido: #{registro.class})"
        end
        unless anterior.nil? || anterior.is_a?(RegistroAnterior)
          raise ValidacionError,
                "entradas[#{i}]: el anterior debe ser RegistroAnterior o nil " \
                "(recibido: #{anterior.class})"
        end
        if anterior.nil? && registro.is_a?(RegistroAnulacion)
          raise ValidacionError,
                "entradas[#{i}]: una anulación no puede iniciar la cadena, exige " \
                'el registro anterior'
        end

        entrada
      end
    end

    # El emisor de cada registro tiene que ser el obligado de la cabecera
    # (Validaciones v1.2.2, ap. 3.1.3.1 y 3.1.4.1). Es una comprobación cruzada
    # entre cabecera y registros, así que solo se puede hacer aquí: un registro
    # aislado no sabe en qué envío acabará.
    def validar_emisores!
      intrusos = entradas.map(&:first).map(&:id_emisor).uniq.reject { |n| n == nif_obligado }
      return if intrusos.empty?

      raise ValidacionError,
            "Todos los registros deben emitirlos el obligado de la cabecera " \
            "(#{nif_obligado}). Ajenos: #{intrusos.join(', ')}"
    end
  end
end
