# frozen_string_literal: true

require 'digest'
require_relative 'importe'
require_relative 'formato'
require_relative 'error'

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
    def alta(**datos)
      digerir(cadena_alta(**datos))
    end

    # Cadena exacta sobre la que se calcula la huella de un ALTA.
    #
    # Es pública a propósito y por dos motivos. Uno: cuando la AEAT rechaza por
    # huella, lo primero que hay que comparar es ESTE string, no el digest. Dos:
    # que los tests puedan afirmar sobre la cadena sin reconstruirla por su
    # cuenta, que es como se quedan ciegos ante un cambio de normalizador.
    def cadena_alta(id_emisor:, num_serie:, fecha_expedicion:, tipo_factura:,
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
      serializar(pares, CAMPOS_ALTA)
    end

    # Huella de un registro de facturación de ANULACIÓN.
    # Aquí huella_anterior es SIEMPRE obligatoria: una anulación nunca puede ser
    # el primer registro de la cadena.
    def anulacion(**datos)
      digerir(cadena_anulacion(**datos))
    end

    # Cadena exacta sobre la que se calcula la huella de una ANULACIÓN.
    def cadena_anulacion(id_emisor:, num_serie:, fecha_expedicion:,
                         fecha_hora_gen:, huella_anterior:)
      if huella_anterior.nil? || huella_anterior.to_s.empty?
        raise ValidacionError,
              'Un registro de anulación exige huella_anterior: no puede iniciar cadena'
      end

      pares = {
        'IDEmisorFacturaAnulada'        => texto(id_emisor, 'IDEmisorFacturaAnulada'),
        'NumSerieFacturaAnulada'        => texto(num_serie, 'NumSerieFacturaAnulada'),
        'FechaExpedicionFacturaAnulada' => fecha(fecha_expedicion),
        'Huella'                        => encadenamiento(huella_anterior),
        'FechaHoraHusoGenRegistro'      => marca_temporal(fecha_hora_gen)
      }
      serializar(pares, CAMPOS_ANULACION)
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
    #
    # texto, fecha y marca_temporal viven en Formato porque el generador de XML
    # necesita exactamente los mismos: si divergieran, la huella que calculamos
    # dejaría de corresponder al XML que enviamos.
    #
    # DELIBERADO: aquí se usa Formato.texto y NO Formato.num_serie, que es el que
    # aplica las restricciones de la AEAT al NumSerieFactura (ASCII 32-126, sin
    # " ' < > =). Este módulo es una primitiva de hash, no la capa de reglas de
    # negocio: debe poder recalcular la huella de CUALQUIER registro, incluido uno
    # que no generamos nosotros. Eso es justo lo que necesitas al depurar un
    # rechazo de la AEAT o al migrar desde otro sistema.
    #
    # Quien construye registros nuevos pasa por RegistroAlta / RegistroAnulacion,
    # y ahí sí se aplican todas las restricciones.

    def texto(valor, campo) = Formato.texto(valor, campo)

    def fecha(valor) = Formato.fecha(valor)

    def marca_temporal(valor) = Formato.marca_temporal(valor)

    def encadenamiento(valor)
      return '' if valor.nil? || valor.to_s.empty?

      cadena = valor.to_s
      unless cadena.match?(PATRON_HUELLA)
        raise ValidacionError,
              "huella_anterior debe ser SHA-256 hex en MAYÚSCULAS (64 chars): #{cadena.inspect}"
      end
      cadena
    end

    private_class_method :texto, :fecha, :encadenamiento, :marca_temporal
  end
end
