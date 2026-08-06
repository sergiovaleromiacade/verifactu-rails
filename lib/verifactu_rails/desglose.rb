# frozen_string_literal: true

require_relative 'formato'
require_relative 'importe'

module VerifactuRails
  # Una línea del desglose de la factura (sf:DetalleType).
  #
  # Todos los importes pasan por Importe.formatear: el string que sale de aquí es
  # el mismo que la AEAT usará para recalcular la huella. No formatear por otro
  # lado, nunca.
  class Detalle
    IMPUESTOS = %w[01 02 03 05].freeze                    # 01 = IVA
    CALIFICACIONES = %w[S1 S2 N1 N2].freeze
    EXENCIONES = %w[E1 E2 E3 E4 E5 E6 E7 E8].freeze
    REGIMENES = %w[01 02 03 04 05 06 07 08 09 10 11 14 15 17 18 19 20 21].freeze

    attr_reader :base_imponible, :calificacion, :exenta, :tipo_impositivo,
                :cuota_repercutida, :impuesto, :clave_regimen,
                :tipo_recargo, :cuota_recargo

    # calificacion y exenta son excluyentes: el XSD las modela como <choice>.
    def initialize(base_imponible:, calificacion: nil, exenta: nil,
                   tipo_impositivo: nil, cuota_repercutida: nil,
                   impuesto: '01', clave_regimen: '01',
                   tipo_recargo: nil, cuota_recargo: nil)
      if calificacion.nil? == exenta.nil?
        raise ArgumentError,
              'Indica exactamente una de calificacion: o exenta: ' \
              '(el esquema las modela como choice, no caben las dos ni ninguna)'
      end

      @base_imponible = Importe.formatear(base_imponible)
      @calificacion = calificacion && Formato.enumerado(calificacion, 'CalificacionOperacion', CALIFICACIONES)
      @exenta = exenta && Formato.enumerado(exenta, 'OperacionExenta', EXENCIONES)
      @impuesto = impuesto && Formato.enumerado(impuesto, 'Impuesto', IMPUESTOS)
      @clave_regimen = clave_regimen && Formato.enumerado(clave_regimen, 'ClaveRegimen', REGIMENES)
      @tipo_impositivo = tipo_impositivo && Importe.formatear(tipo_impositivo)
      @cuota_repercutida = cuota_repercutida && Importe.formatear(cuota_repercutida)
      @tipo_recargo = tipo_recargo && Importe.formatear(tipo_recargo)
      @cuota_recargo = cuota_recargo && Importe.formatear(cuota_recargo)

      validar_coherencia!
    end

    def exenta? = !@exenta.nil?

    # Orden EXACTO de sf:DetalleType (<sequence>).
    def a_pares
      pares = {}
      pares['Impuesto'] = impuesto if impuesto
      pares['ClaveRegimen'] = clave_regimen if clave_regimen
      if exenta?
        pares['OperacionExenta'] = exenta
      else
        pares['CalificacionOperacion'] = calificacion
      end
      pares['TipoImpositivo'] = tipo_impositivo if tipo_impositivo
      pares['BaseImponibleOimporteNoSujeto'] = base_imponible
      pares['CuotaRepercutida'] = cuota_repercutida if cuota_repercutida
      pares['TipoRecargoEquivalencia'] = tipo_recargo if tipo_recargo
      pares['CuotaRecargoEquivalencia'] = cuota_recargo if cuota_recargo
      pares
    end

    private

    def validar_coherencia!
      if exenta? && cuota_repercutida
        raise ArgumentError,
              'Una operación exenta no puede llevar CuotaRepercutida'
      end
      if cuota_recargo && tipo_recargo.nil?
        raise ArgumentError,
              'CuotaRecargoEquivalencia exige TipoRecargoEquivalencia'
      end
    end
  end

  # Conjunto de líneas del desglose (sf:DesgloseType).
  class Desglose
    MAXIMO_LINEAS = 12 # maxOccurs del esquema; no es orientativo

    attr_reader :detalles

    def initialize(detalles)
      @detalles = Array(detalles)

      raise ArgumentError, 'El desglose necesita al menos una línea' if @detalles.empty?

      if @detalles.size > MAXIMO_LINEAS
        raise ArgumentError,
              "El desglose admite como mucho #{MAXIMO_LINEAS} líneas " \
              "(recibidas #{@detalles.size}). Agrupa por tipo impositivo."
      end

      unless @detalles.all?(Detalle)
        raise ArgumentError, 'Todas las líneas deben ser VerifactuRails::Detalle'
      end
    end

    # Suma de cuotas repercutidas y de recargos. Se ofrece como ayuda para
    # rellenar CuotaTotal, pero NO se impone: la relación entre el desglose y los
    # totales tiene casos límite (rectificativas, no sujetas) y preferimos que el
    # importe que se envía sea siempre el que decide quien llama.
    def cuota_total
      suma = detalles.sum do |d|
        BigDecimal(d.cuota_repercutida || '0') + BigDecimal(d.cuota_recargo || '0')
      end
      Importe.formatear(suma)
    end

    def base_total
      Importe.formatear(detalles.sum { |d| BigDecimal(d.base_imponible) })
    end
  end
end
