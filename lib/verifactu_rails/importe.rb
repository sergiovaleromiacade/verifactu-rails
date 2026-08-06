# frozen_string_literal: true

require 'bigdecimal'
require 'bigdecimal/util'
require_relative 'error'

module VerifactuRails
  # Formateo canónico de importes monetarios.
  #
  # REGLA DE ORO: el string que produce este módulo es el que debe ir TANTO en la
  # cadena de la huella COMO en el XML. Si divergen aunque sea en un decimal, la
  # AEAT recalcula la huella sobre lo que recibe en el XML y rechaza el registro.
  # Por eso el formateo vive aquí y en un solo sitio.
  module Importe
    PATRON = /\A-?\d{1,12}\.\d{2}\z/

    module_function

    # Normaliza a string con exactamente 2 decimales y punto como separador.
    # Acepta BigDecimal, Integer, Rational o String; rechaza Float por
    # imprecisión binaria (0.1 + 0.2 no es 0.3 y aquí eso es un rechazo AEAT).
    def formatear(valor)
      case valor
      when Float
        raise ValidacionError,
              'No se admiten Float en importes: usa BigDecimal, Integer o String ' \
              "(recibido: #{valor.inspect})"
      when BigDecimal then decimal = valor
      when Integer    then decimal = valor.to_d
      when Rational   then decimal = valor.to_d(20)
      when String     then decimal = parsear_string(valor)
      when nil        then raise ValidacionError, 'Importe requerido'
      else
        raise ValidacionError, "Tipo de importe no admitido: #{valor.class}"
      end

      # ROUND_HALF_UP: el redondeo bancario (HALF_EVEN) de Ruby por defecto
      # no es el que aplica la normativa fiscal española.
      resultado = decimal.round(2, BigDecimal::ROUND_HALF_UP).to_s('F')
      resultado = format('%.2f', resultado.to_d) # asegura los 2 decimales

      unless resultado.match?(PATRON)
        raise ValidacionError, "Importe fuera de rango o mal formado: #{resultado}"
      end

      # -0.00 no existe fiscalmente y rompería la comparación de huellas
      resultado == '-0.00' ? '0.00' : resultado
    end

    # sf:Tipo2.2Type, para los porcentajes: patrón \d{1,3}(\.\d{0,2})? — SIN
    # signo y con tres dígitos enteros como mucho. Es un tipo distinto de
    # sf:ImporteSgn12.2Type, así que formatear con `formatear` a secas dejaba
    # pasar un -21.00 o un 1000.00 que luego rechaza el esquema.
    def porcentaje(valor, campo)
      cadena = formatear(valor)
      unless cadena.match?(/\A\d{1,3}\.\d{2}\z/)
        raise ValidacionError,
              "#{campo} debe ser un porcentaje sin signo y de hasta 3 dígitos " \
              "enteros (recibido: #{cadena})"
      end

      cadena
    end

    def parsear_string(cadena)
      texto = cadena.strip
      unless texto.match?(/\A-?\d+([.,]\d+)?\z/)
        raise ValidacionError, "Importe no numérico: #{cadena.inspect}"
      end

      texto.tr(',', '.').to_d
    end
    private_class_method :parsear_string
  end
end
