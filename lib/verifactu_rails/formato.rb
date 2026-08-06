# frozen_string_literal: true

require 'time'
require 'date'

module VerifactuRails
  # Normalización canónica de los valores que aparecen a la vez en la cadena de la
  # huella y en el XML.
  #
  # REGLA DE ORO, la misma que rige Importe: la AEAT recalcula la huella sobre lo
  # que recibe en el XML. Si un valor se normaliza distinto en cada sitio, rechazo.
  # Por eso fechas y marcas temporales viven aquí y no duplicadas en cada módulo.
  #
  # (El escapado XML es harina de otro costal y no rompe esta regla: la huella se
  # calcula sobre el valor crudo y el XML lo escapa, pero la AEAT desescapa antes
  # de recalcular. Una serie "A&B" va cruda a la huella y como "A&amp;B" al XML.)
  module Formato
    module_function

    # Los espacios al principio/final son la ambigüedad clásica de la spec.
    # En vez de decidir por el usuario (trim sí/no), rechazamos: que falle aquí
    # y no seis meses después con una cadena rota en producción.
    def texto(valor, campo)
      cadena = valor.to_s
      raise ArgumentError, "#{campo} no puede estar vacío" if cadena.empty?

      if cadena != cadena.strip
        raise ArgumentError,
              "#{campo} contiene espacios al inicio o final: #{cadena.inspect}. " \
              'Normalízalo antes de generar el registro.'
      end
      cadena
    end

    # Tipo sf:fecha del XSD: exactamente dd-mm-yyyy.
    def fecha(valor)
      objeto = valor.is_a?(String) ? Date.strptime(valor, '%d-%m-%Y') : valor
      objeto.strftime('%d-%m-%Y')
    rescue ArgumentError, TypeError
      raise ArgumentError, "Fecha inválida (se espera Date o 'dd-mm-yyyy'): #{valor.inspect}"
    end

    # ISO 8601 con offset explícito. OJO: Ruby serializa UTC como "Z" mientras
    # que la referencia usa "+00:00"; forzamos siempre ±HH:MM para que la huella
    # coincida con la de otras implementaciones y con el XML.
    def marca_temporal(valor)
      tiempo = valor.is_a?(String) ? Time.iso8601(valor) : valor
      raise ArgumentError, 'fecha_hora_gen debe ser Time o String ISO 8601' unless tiempo.respond_to?(:strftime)

      tiempo.strftime('%Y-%m-%dT%H:%M:%S%:z')
    rescue ArgumentError => e
      raise ArgumentError, "fecha_hora_gen inválida: #{valor.inspect} (#{e.message})"
    end

    # Longitud fija de 9 según sf:NIFType. El XSD no valida el dígito de control,
    # y nosotros tampoco: rechazar un NIF válido por una tabla desactualizada
    # sería peor que dejar que la AEAT lo rechace.
    def nif(valor, campo = 'NIF')
      cadena = texto(valor, campo)
      unless cadena.length == 9
        raise ArgumentError, "#{campo} debe tener 9 caracteres: #{cadena.inspect}"
      end

      cadena
    end

    def limitar(valor, campo, maximo)
      cadena = texto(valor, campo)
      if cadena.length > maximo
        raise ArgumentError,
              "#{campo} excede #{maximo} caracteres (#{cadena.length}): #{cadena.inspect}"
      end

      cadena
    end

    def enumerado(valor, campo, admitidos)
      cadena = texto(valor, campo)
      unless admitidos.include?(cadena)
        raise ArgumentError,
              "#{campo} inválido: #{cadena.inspect}. Admitidos: #{admitidos.join(', ')}"
      end

      cadena
    end
  end
end
