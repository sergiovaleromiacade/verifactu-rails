# frozen_string_literal: true

require 'digest'
require 'time'
require 'date'
require_relative 'importe'

module VerifactuRails
  # Cálculo de la huella (hash) de los registros de facturación.
  #
  # Referencia normativa: RD 1007/2023 art. 7, Orden HAC/1177/2024, y el documento
  # "Detalle de las especificaciones técnicas para la generación de la huella o hash
  # de los registros" publicado en la web de desarrolladores de la AEAT.
  #
  # La cadena se construye como pares "Campo=valor" unidos por "&", SIN escapado
  # de los valores, y se le aplica SHA-256 devuelto en hexadecimal MAYÚSCULAS.
  module Huella
    PATRON_HUELLA = /\A[0-9A-F]{64}\z/
    CAMPOS_ALTA = %w[
      IDEmisorFactura NumSerieFactura FechaExpedicionFactura
      TipoFactura CuotaTotal ImporteTotal Huella FechaHoraHusoGenRegistro
    ].freeze
    CAMPOS_ANULACION = %w[
      IDEmisorFacturaAnulada NumSerieFacturaAnulada FechaExpedicionFacturaAnulada
      Huella FechaHoraHusoGenRegistro
    ].freeze

    module_function

    # Huella de un registro de facturación de ALTA.
    #
    # @param huella_anterior [String, nil] huella del registro previo de la cadena.
    #   nil o "" únicamente para el primer registro del NIF+serie.
    def alta(id_emisor:, num_serie:, fecha_expedicion:, tipo_factura:,
             cuota_total:, importe_total:, fecha_hora_gen:, huella_anterior: nil)
      pares = {
        'IDEmisorFactura'          => texto(id_emisor, 'IDEmisorFactura'),
        'NumSerieFactura'          => texto(num_serie, 'NumSerieFactura'),
        'FechaExpedicionFactura'   => fecha(fecha_expedicion),
        'TipoFactura'              => texto(tipo_factura, 'TipoFactura'),
        'CuotaTotal'               => Importe.formatear(cuota_total),
        'ImporteTotal'             => Importe.formatear(importe_total),
        'Huella'                   => encadenamiento(huella_anterior),
        'FechaHoraHusoGenRegistro' => marca_temporal(fecha_hora_gen)
      }
      digerir(serializar(pares, CAMPOS_ALTA))
    end

    # Huella de un registro de facturación de ANULACIÓN.
    # Aquí huella_anterior es SIEMPRE obligatoria: una anulación nunca puede ser
    # el primer registro de la cadena.
    def anulacion(id_emisor:, num_serie:, fecha_expedicion:,
                  fecha_hora_gen:, huella_anterior:)
      if huella_anterior.nil? || huella_anterior.to_s.empty?
        raise ArgumentError,
              'Un registro de anulación exige huella_anterior: no puede iniciar cadena'
      end

      pares = {
        'IDEmisorFacturaAnulada'        => texto(id_emisor, 'IDEmisorFacturaAnulada'),
        'NumSerieFacturaAnulada'        => texto(num_serie, 'NumSerieFacturaAnulada'),
        'FechaExpedicionFacturaAnulada' => fecha(fecha_expedicion),
        'Huella'                        => encadenamiento(huella_anterior),
        'FechaHoraHusoGenRegistro'      => marca_temporal(fecha_hora_gen)
      }
      digerir(serializar(pares, CAMPOS_ANULACION))
    end

    # Expone la cadena previa al hash. Imprescindible para depurar: cuando la AEAT
    # rechaza por huella, lo primero es comparar ESTE string, no el digest.
    def serializar(pares, orden)
      orden.map { |campo| "#{campo}=#{pares.fetch(campo)}" }.join('&')
    end

    def digerir(cadena)
      Digest::SHA256.hexdigest(cadena.encode(Encoding::UTF_8)).upcase
    end

    # --- normalizadores -------------------------------------------------------

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

    def fecha(valor)
      objeto = valor.is_a?(String) ? Date.strptime(valor, '%d-%m-%Y') : valor
      objeto.strftime('%d-%m-%Y')
    rescue ArgumentError, TypeError
      raise ArgumentError, "Fecha inválida (se espera Date o 'dd-mm-yyyy'): #{valor.inspect}"
    end

    def encadenamiento(valor)
      return '' if valor.nil? || valor.to_s.empty?

      cadena = valor.to_s
      unless cadena.match?(PATRON_HUELLA)
        raise ArgumentError,
              "huella_anterior debe ser SHA-256 hex en MAYÚSCULAS (64 chars): #{cadena.inspect}"
      end
      cadena
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

    private_class_method :texto, :fecha, :encadenamiento, :marca_temporal
  end
end
