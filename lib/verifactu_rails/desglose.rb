# frozen_string_literal: true

require 'date' # VENTANAS_TIPO y RECARGOS_POR_TIPO construyen Date al cargar
require_relative 'formato'
require_relative 'importe'
require_relative 'error'

module VerifactuRails
  # Una línea del desglose de la factura (sf:DetalleType).
  #
  # Todos los importes pasan por Importe.formatear: el string que sale de aquí es
  # el mismo que la AEAT usará para recalcular la huella. No formatear por otro
  # lado, nunca.
  class Detalle
    IMPUESTOS = %w[01 02 03 05].freeze # 01 IVA, 02 IPSI, 03 IGIC, 05 Otros
    CALIFICACIONES = %w[S1 S2 N1 N2].freeze

    # Lista L10. E7 y E8 NO son valores generales: solo se admiten con IGIC
    # (Validaciones v1.2.2, ap. 15.5).
    EXENCIONES = %w[E1 E2 E3 E4 E5 E6].freeze
    EXENCIONES_IGIC = (EXENCIONES + %w[E7 E8]).freeze

    # ClaveRegimen admisible por impuesto: L8A para IVA, L8B (+20) para IGIC y el
    # subconjunto del ap. 15.6 para IPSI. Con Impuesto = 05 (Otros) el campo no
    # se puede informar en absoluto.
    REGIMENES_IVA = %w[01 02 03 04 05 06 07 08 09 10 11 14 15 17 18 19 20].freeze
    REGIMENES_IGIC = (REGIMENES_IVA + %w[21]).freeze
    REGIMENES_IPSI = %w[01 08 11 18 19 20].freeze
    REGIMENES = (REGIMENES_IGIC | REGIMENES_IVA).freeze

    # Ap. 15.1 y 15.3, para IVA con operación sujeta y no exenta.
    TIPOS_IMPOSITIVOS_IVA = %w[0.00 2.00 4.00 5.00 7.50 10.00 21.00].freeze
    RECARGOS_IVA = %w[0.00 0.26 0.50 0.62 1.00 1.40 1.75 5.20].freeze

    # Ap. 15.1. Tres de los tipos NO son de aplicación permanente: fueron
    # rebajas temporales y solo se admiten si la fecha de referencia cae dentro
    # de su ventana. Los demás no llevan ventana.
    #
    # Consecuencia práctica que sorprende: como FechaExpedicionFactura no puede
    # ser anterior al 28-10-2024, el 5 % ya NO es declarable salvo que se informe
    # una FechaOperacion dentro de su ventana. Es el origen de los errores 1235 y
    # 1236 de la AEAT.
    VENTANAS_TIPO = {
      '5.00' => [Date.new(2022, 7, 1), Date.new(2024, 9, 30)],
      '2.00' => [Date.new(2024, 10, 1), Date.new(2024, 12, 31)],
      '7.50' => [Date.new(2024, 10, 1), Date.new(2024, 12, 31)]
    }.freeze

    # Ap. 15.3. Qué recargo de equivalencia admite cada tipo impositivo. Cada
    # entrada es [ventana, recargos]; ventana nil significa "siempre".
    #
    # Solo se exige lo que la norma afirma. Para el 0 % y el 5 % fuera de sus
    # ventanas el texto no dice nada, y ahí NO se inventa una restricción: ser
    # más estricto que la norma ya bloqueó casos válidos antes en esta gema.
    RECARGOS_POR_TIPO = {
      '21.00' => [[nil, %w[5.20 1.75]]],
      '10.00' => [[nil, %w[1.40]]],
      '7.50' => [[nil, %w[1.00]]],
      '4.00' => [[nil, %w[0.50]]],
      '2.00' => [[nil, %w[0.26]]],
      '5.00' => [[[nil, Date.new(2022, 12, 31)], %w[0.50]],
                 [[Date.new(2023, 1, 1), Date.new(2024, 9, 30)], %w[0.62]]],
      '0.00' => [[[Date.new(2023, 1, 1), Date.new(2024, 9, 30)], %w[0.00]]]
    }.freeze

    # Campos que solo tienen sentido en una operación sujeta y no exenta.
    CAMPOS_DE_SUJECION = %i[tipo_impositivo cuota_repercutida
                            tipo_recargo cuota_recargo].freeze

    attr_reader :base_imponible, :calificacion, :exenta, :tipo_impositivo,
                :cuota_repercutida, :impuesto, :clave_regimen,
                :tipo_recargo, :cuota_recargo

    # calificacion y exenta son excluyentes: el XSD las modela como <choice>.
    def initialize(base_imponible:, calificacion: nil, exenta: nil,
                   tipo_impositivo: nil, cuota_repercutida: nil,
                   impuesto: '01', clave_regimen: '01',
                   tipo_recargo: nil, cuota_recargo: nil)
      if calificacion.nil? == exenta.nil?
        raise ValidacionError,
              'Indica exactamente una de calificacion: o exenta: ' \
              '(el esquema las modela como choice, no caben las dos ni ninguna)'
      end

      @base_imponible = Importe.formatear(base_imponible)
      @calificacion = calificacion && Formato.enumerado(calificacion, 'CalificacionOperacion', CALIFICACIONES)
      @impuesto = impuesto && Formato.enumerado(impuesto, 'Impuesto', IMPUESTOS)
      @exenta = exenta && Formato.enumerado(exenta, 'OperacionExenta', exenciones_admitidas)
      # Sin normalizar todavía: con Impuesto=05 no cabe ninguna clave, y un
      # enumerado de lista vacía daría "Admitidos: " en lugar del motivo real.
      # validar_clave_regimen! resuelve primero ese caso.
      @clave_regimen = clave_regimen&.to_s
      @tipo_impositivo = tipo_impositivo && Importe.porcentaje(tipo_impositivo, 'TipoImpositivo')
      @cuota_repercutida = cuota_repercutida && Importe.formatear(cuota_repercutida)
      @tipo_recargo = tipo_recargo && Importe.porcentaje(tipo_recargo, 'TipoRecargoEquivalencia')
      @cuota_recargo = cuota_recargo && Importe.formatear(cuota_recargo)

      validar_coherencia!
    end

    def exenta? = !@exenta.nil?

    # Reglas del ap. 15.1 y 15.3 que dependen de la fecha de la operación, que
    # esta clase no conoce: la aporta RegistroAlta, que es quien sabe si hay
    # FechaOperacion o hay que caer en FechaExpedicionFactura. Se deja aquí y no
    # allí para que la tabla viva junto al resto de reglas del desglose.
    #
    # Ambas cuelgan de "Impuesto = 01 (IVA) y CalificacionOperacion = S1".
    def validar_en_fecha!(fecha)
      return unless iva? && calificacion == 'S1'

      validar_ventana_tipo!(fecha)
      validar_recargo_en_fecha!(fecha)
    end

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

    def iva? = impuesto.nil? || impuesto == '01' # si no se informa, se asume IVA

    private

    def exenciones_admitidas = impuesto == '03' ? EXENCIONES_IGIC : EXENCIONES

    # Ap. 15.6. Con Impuesto = 05 (Otros) el campo no se puede informar; ahí la
    # lista vacía hace que Formato.enumerado rechace cualquier valor.
    def regimenes_admitidos
      case impuesto
      when '02' then REGIMENES_IPSI
      when '03' then REGIMENES_IGIC
      when '05' then []
      else REGIMENES_IVA
      end
    end

    def presentes(campos) = campos.select { |c| !send(c).nil? }

    def validar_coherencia!
      validar_clave_regimen!
      validar_exenta!
      validar_calificacion!
      validar_recargo!
    end

    # Ap. 15.6: solo cabe con IVA, IPSI o IGIC, y ahí es obligatorio.
    def validar_clave_regimen!
      if impuesto == '05'
        return if clave_regimen.nil?

        raise ValidacionError, 'ClaveRegimen no se puede informar con Impuesto=05 (Otros)'
      end
      if clave_regimen.nil?
        raise ValidacionError, "ClaveRegimen es obligatorio con Impuesto=#{impuesto || '01'}"
      end

      @clave_regimen = Formato.enumerado(clave_regimen, 'ClaveRegimen', regimenes_admitidos)
    end

    # Ap. 15.5: una exenta no admite ninguno de los campos de sujeción.
    def validar_exenta!
      return unless exenta?

      sobran = presentes(CAMPOS_DE_SUJECION)
      unless sobran.empty?
        raise ValidacionError,
              "Una operación exenta (#{exenta}) no admite #{sobran.join(', ')}"
      end
      return unless %w[E2 E3].include?(exenta) && clave_regimen == '01' && (iva? || impuesto == '03')

      raise ValidacionError,
            "OperacionExenta #{exenta} no cabe con ClaveRegimen=01"
    end

    # Ap. 15.4 y 15.7.
    def validar_calificacion!
      case calificacion
      when 'S1' then validar_sujeta_no_exenta!
      when 'S2'
        # Inversión del sujeto pasivo: la cuota la repercute el destinatario.
        unless tipo_impositivo == '0.00' && cuota_repercutida == '0.00'
          raise ValidacionError,
                'CalificacionOperacion S2 (inversión del sujeto pasivo) exige ' \
                'tipo_impositivo y cuota_repercutida a cero, ambos informados'
        end
      when 'N1', 'N2'
        return unless iva?

        sobran = presentes(CAMPOS_DE_SUJECION)
        return if sobran.empty?

        raise ValidacionError,
              "Una operación no sujeta (#{calificacion}) no admite #{sobran.join(', ')}"
      end
    end

    def validar_sujeta_no_exenta!
      if tipo_impositivo.nil? || cuota_repercutida.nil?
        raise ValidacionError,
              'CalificacionOperacion S1 exige tipo_impositivo y cuota_repercutida'
      end
      return unless iva? && !TIPOS_IMPOSITIVOS_IVA.include?(tipo_impositivo)

      raise ValidacionError,
            "TipoImpositivo #{tipo_impositivo} no existe en IVA. " \
            "Admitidos: #{TIPOS_IMPOSITIVOS_IVA.join(', ')}"
    end

    def validar_ventana_tipo!(fecha)
      desde, hasta = VENTANAS_TIPO[tipo_impositivo]
      return if desde.nil? || fecha.between?(desde, hasta)

      raise ValidacionError,
            "TipoImpositivo #{tipo_impositivo} solo se admite entre " \
            "#{desde.strftime('%d-%m-%Y')} y #{hasta.strftime('%d-%m-%Y')} " \
            "(fecha de referencia: #{fecha.strftime('%d-%m-%Y')}). Fue una rebaja " \
            'temporal; si la operación es de aquellas fechas, informa fecha_operacion.'
    end

    def validar_recargo_en_fecha!(fecha)
      return if tipo_recargo.nil?

      tramos = RECARGOS_POR_TIPO[tipo_impositivo] || []
      tramo = tramos.find { |ventana, _| en_ventana?(ventana, fecha) }
      return if tramo.nil? || tramo[1].include?(tipo_recargo)

      raise ValidacionError,
            "Con TipoImpositivo #{tipo_impositivo}, el recargo de equivalencia solo " \
            "puede ser #{tramo[1].join(' o ')} (recibido #{tipo_recargo})"
    end

    def en_ventana?(ventana, fecha)
      return true if ventana.nil?

      desde, hasta = ventana
      (desde.nil? || fecha >= desde) && (hasta.nil? || fecha <= hasta)
    end

    def validar_recargo!
      if cuota_recargo && tipo_recargo.nil?
        raise ValidacionError, 'CuotaRecargoEquivalencia exige TipoRecargoEquivalencia'
      end
      return unless tipo_recargo && iva? && calificacion == 'S1'
      return if RECARGOS_IVA.include?(tipo_recargo)

      raise ValidacionError,
            "TipoRecargoEquivalencia #{tipo_recargo} no existe en IVA. " \
            "Admitidos: #{RECARGOS_IVA.join(', ')}"
    end
  end

  # Conjunto de líneas del desglose (sf:DesgloseType).
  class Desglose
    MAXIMO_LINEAS = 12 # maxOccurs del esquema; no es orientativo

    attr_reader :detalles

    def initialize(detalles)
      @detalles = Array(detalles)

      raise ValidacionError, 'El desglose necesita al menos una línea' if @detalles.empty?

      if @detalles.size > MAXIMO_LINEAS
        raise ValidacionError,
              "El desglose admite como mucho #{MAXIMO_LINEAS} líneas " \
              "(recibidas #{@detalles.size}). Agrupa por tipo impositivo."
      end

      unless @detalles.all?(Detalle)
        raise ValidacionError, 'Todas las líneas deben ser VerifactuRails::Detalle'
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
