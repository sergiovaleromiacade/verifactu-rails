# frozen_string_literal: true

require_relative 'formato'
require_relative 'importe'
require_relative 'huella'
require_relative 'desglose'
require_relative 'sistema_informatico'

module VerifactuRails
  IDVERSION = '1.0'   # sf:VersionType solo admite este valor
  TIPO_HUELLA = '01'  # sf:TipoHuellaType solo admite este valor

  # Espacios de nombres. Son URLs de www2 aunque los XSD se descarguen de
  # prewww2: el targetNamespace de los esquemas apunta a producción en ambos
  # entornos, y es el targetNamespace lo que manda.
  NS_SF = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/' \
          'dep/aplicaciones/es/aeat/tike/cont/ws/SuministroInformacion.xsd'
  NS_LR = 'https://www2.agenciatributaria.gob.es/static_files/common/internet/' \
          'dep/aplicaciones/es/aeat/tike/cont/ws/SuministroLR.xsd'

  # Identificación de la factura anterior de la cadena (sf:EncadenamientoFactura-
  # AnteriorType). No basta con la huella previa: el registro anterior se
  # identifica por emisor, serie y fecha además del hash.
  class RegistroAnterior
    attr_reader :id_emisor, :num_serie, :fecha_expedicion, :huella

    def initialize(id_emisor:, num_serie:, fecha_expedicion:, huella:)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFactura anterior')
      @num_serie = Formato.num_serie(num_serie)
      @fecha_expedicion = Formato.fecha(fecha_expedicion)
      @huella = Formato.limitar(huella, 'Huella anterior', 64)

      unless @huella.match?(Huella::PATRON_HUELLA)
        raise ArgumentError,
              "La huella anterior debe ser SHA-256 hex en MAYÚSCULAS: #{@huella.inspect}"
      end
    end

    def a_pares
      { 'IDEmisorFactura' => id_emisor, 'NumSerieFactura' => num_serie,
        'FechaExpedicionFactura' => fecha_expedicion, 'Huella' => huella }
    end
  end

  # Identificación de una factura ajena a la que este registro se refiere:
  # rectificada o sustituida (sf:IDFacturaARType). Son los mismos tres campos que
  # identifican cualquier factura, sin la huella.
  class IdFactura
    attr_reader :id_emisor, :num_serie, :fecha_expedicion

    def initialize(id_emisor:, num_serie:, fecha_expedicion:)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFactura')
      @num_serie = Formato.num_serie(num_serie)
      @fecha_expedicion = Formato.fecha(fecha_expedicion)
    end

    def a_pares
      { 'IDEmisorFactura' => id_emisor, 'NumSerieFactura' => num_serie,
        'FechaExpedicionFactura' => fecha_expedicion }
    end
  end

  # Base y cuota de lo que se sustituye (sf:DesgloseRectificacionType).
  #
  # Solo tiene sentido en rectificativas POR SUSTITUCIÓN: la factura reexpresa el
  # importe corregido completo, así que hay que declarar cuál era el original. En
  # las incrementales los importes de la propia factura YA son la diferencia, y no
  # hay nada que sustituir.
  class ImporteRectificacion
    attr_reader :base, :cuota, :cuota_recargo

    def initialize(base:, cuota:, cuota_recargo: nil)
      @base = Importe.formatear(base)
      @cuota = Importe.formatear(cuota)
      @cuota_recargo = cuota_recargo && Importe.formatear(cuota_recargo)
    end

    def a_pares
      pares = { 'BaseRectificada' => base, 'CuotaRectificada' => cuota }
      pares['CuotaRecargoRectificado'] = cuota_recargo if cuota_recargo
      pares
    end
  end

  # Un destinatario de la factura (sf:PersonaFisicaJuridicaType).
  # El NIF español y la identificación extranjera son excluyentes (<choice>).
  class Destinatario
    attr_reader :nombre_razon, :nif, :id_otro

    # @param id_otro [Hash, nil] para no residentes:
    #   { codigo_pais: 'FR', id_type: '02', id: 'FR12345678901' }
    def initialize(nombre_razon:, nif: nil, id_otro: nil)
      if nif.nil? == id_otro.nil?
        raise ArgumentError,
              'Indica exactamente uno de nif: o id_otro: para el destinatario'
      end

      @nombre_razon = Formato.limitar(nombre_razon, 'NombreRazon', 120)
      @nif = nif && Formato.nif(nif, 'NIF del destinatario')
      @id_otro = id_otro && normalizar_id_otro(id_otro)
    end

    private

    def normalizar_id_otro(datos)
      {
        'CodigoPais' => datos[:codigo_pais] &&
          Formato.limitar(datos[:codigo_pais], 'CodigoPais', 2),
        'IDType' => Formato.limitar(datos.fetch(:id_type), 'IDType', 2),
        'ID' => Formato.limitar(datos.fetch(:id), 'ID', 20)
      }.compact
    end
  end

  # Registro de facturación de ALTA.
  #
  # El punto entero de esta clase: la huella y el XML salen de los MISMOS campos
  # ya normalizados. Calcular una por un lado y montar el otro por otro es el bug
  # número uno del dominio, porque la AEAT recalcula la huella sobre el XML que
  # recibe. Aquí eso no puede pasar por construcción.
  class RegistroAlta
    TIPOS_FACTURA = %w[F1 F2 F3 R1 R2 R3 R4 R5].freeze
    TIPOS_RECTIFICATIVA = %w[S I].freeze # S = sustitutiva, I = incremental
    MAXIMO_REFERENCIADAS = 1000          # maxOccurs del esquema

    # Destinatarios: obligatorio en unos tipos, prohibido en otros
    # (Validaciones v1.2.2, ap. 3.1.3.13). F2 y R5 son las simplificadas, donde
    # por definición no se identifica al destinatario.
    TIPOS_CON_DESTINATARIO = %w[F1 F3 R1 R2 R3 R4].freeze
    TIPOS_SIN_DESTINATARIO = %w[F2 R5].freeze

    # Entrada en vigor de la Orden HAC/1177/2024.
    FECHA_MINIMA = Date.new(2024, 10, 28)

    attr_reader :id_emisor, :num_serie, :fecha_expedicion, :nombre_razon_emisor,
                :tipo_factura, :descripcion_operacion, :desglose, :cuota_total,
                :importe_total, :sistema_informatico, :fecha_hora_gen,
                :destinatarios, :fecha_operacion, :tipo_rectificativa,
                :facturas_rectificadas, :facturas_sustituidas,
                :importe_rectificacion

    def initialize(id_emisor:, num_serie:, fecha_expedicion:, nombre_razon_emisor:,
                   tipo_factura:, descripcion_operacion:, desglose:,
                   cuota_total:, importe_total:, sistema_informatico:,
                   fecha_hora_gen:, destinatarios: [], fecha_operacion: nil,
                   tipo_rectificativa: nil, facturas_rectificadas: [],
                   facturas_sustituidas: [], importe_rectificacion: nil)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFactura')
      @num_serie = Formato.num_serie(num_serie)
      @fecha_expedicion = Formato.fecha(fecha_expedicion)
      @nombre_razon_emisor = Formato.limitar(nombre_razon_emisor, 'NombreRazonEmisor', 120)
      @tipo_factura = Formato.enumerado(tipo_factura, 'TipoFactura', TIPOS_FACTURA)
      @descripcion_operacion = Formato.limitar(descripcion_operacion, 'DescripcionOperacion', 500)
      @desglose = desglose.is_a?(Desglose) ? desglose : Desglose.new(desglose)
      @cuota_total = Importe.formatear(cuota_total)
      @importe_total = Importe.formatear(importe_total)
      @sistema_informatico = sistema_informatico
      @fecha_hora_gen = Formato.marca_temporal(fecha_hora_gen)
      @destinatarios = Array(destinatarios)
      @fecha_operacion = fecha_operacion && Formato.fecha(fecha_operacion)
      @tipo_rectificativa = tipo_rectificativa &&
                            Formato.enumerado(tipo_rectificativa, 'TipoRectificativa', TIPOS_RECTIFICATIVA)
      @facturas_rectificadas = Array(facturas_rectificadas)
      @facturas_sustituidas = Array(facturas_sustituidas)
      @importe_rectificacion = importe_rectificacion

      unless @sistema_informatico.is_a?(SistemaInformatico)
        raise ArgumentError, 'sistema_informatico debe ser VerifactuRails::SistemaInformatico'
      end
      if @destinatarios.size > MAXIMO_REFERENCIADAS
        raise ArgumentError, "Como mucho #{MAXIMO_REFERENCIADAS} destinatarios por registro"
      end

      validar_fecha_expedicion!(fecha_expedicion)
      validar_destinatarios!
      validar_rectificativa!
      validar_sustitutiva!
    end

    def rectificativa? = tipo_factura.start_with?('R')

    # Huella de este registro. `anterior` es nil solo en el primer registro de la
    # cadena del NIF+serie.
    #
    # @param anterior [RegistroAnterior, nil]
    def huella(anterior: nil)
      Huella.alta(
        id_emisor: id_emisor, num_serie: num_serie,
        fecha_expedicion: fecha_expedicion, tipo_factura: tipo_factura,
        cuota_total: cuota_total, importe_total: importe_total,
        fecha_hora_gen: fecha_hora_gen,
        huella_anterior: anterior&.huella
      )
    end

    # Emite el subárbol sf:RegistroAlta dentro de un builder ya posicionado.
    def construir(xml, anterior: nil)
      propia = huella(anterior: anterior)

      xml['sf'].RegistroAlta do
        xml['sf'].IDVersion IDVERSION
        xml['sf'].IDFactura do
          xml['sf'].IDEmisorFactura id_emisor
          xml['sf'].NumSerieFactura num_serie
          xml['sf'].FechaExpedicionFactura fecha_expedicion
        end
        xml['sf'].NombreRazonEmisor nombre_razon_emisor
        xml['sf'].TipoFactura tipo_factura
        xml['sf'].TipoRectificativa tipo_rectificativa if tipo_rectificativa
        construir_referenciadas(xml, 'FacturasRectificadas', 'IDFacturaRectificada',
                                facturas_rectificadas)
        construir_referenciadas(xml, 'FacturasSustituidas', 'IDFacturaSustituida',
                                facturas_sustituidas)
        if importe_rectificacion
          xml['sf'].ImporteRectificacion do
            importe_rectificacion.a_pares.each { |campo, valor| xml['sf'].send(campo, valor) }
          end
        end
        xml['sf'].FechaOperacion fecha_operacion if fecha_operacion
        xml['sf'].DescripcionOperacion descripcion_operacion
        construir_destinatarios(xml)
        construir_desglose(xml)
        xml['sf'].CuotaTotal cuota_total
        xml['sf'].ImporteTotal importe_total
        construir_encadenamiento(xml, anterior)
        construir_sistema(xml)
        xml['sf'].FechaHoraHusoGenRegistro fecha_hora_gen
        xml['sf'].TipoHuella TIPO_HUELLA
        xml['sf'].Huella propia
      end
    end

    private

    def construir_destinatarios(xml)
      return if destinatarios.empty?

      xml['sf'].Destinatarios do
        destinatarios.each do |d|
          xml['sf'].IDDestinatario do
            xml['sf'].NombreRazon d.nombre_razon
            if d.nif
              xml['sf'].NIF d.nif
            else
              xml['sf'].IDOtro { d.id_otro.each { |k, v| xml['sf'].send(k, v) } }
            end
          end
        end
      end
    end

    def construir_desglose(xml)
      xml['sf'].Desglose do
        desglose.detalles.each do |detalle|
          xml['sf'].DetalleDesglose do
            detalle.a_pares.each { |campo, valor| xml['sf'].send(campo, valor) }
          end
        end
      end
    end

    def construir_encadenamiento(xml, anterior)
      xml['sf'].Encadenamiento do
        if anterior.nil?
          xml['sf'].PrimerRegistro 'S'
        else
          xml['sf'].RegistroAnterior do
            anterior.a_pares.each { |campo, valor| xml['sf'].send(campo, valor) }
          end
        end
      end
    end

    def construir_sistema(xml)
      xml['sf'].SistemaInformatico do
        sistema_informatico.a_pares.each { |campo, valor| xml['sf'].send(campo, valor) }
      end
    end

    def construir_referenciadas(xml, envoltorio, elemento, facturas)
      return if facturas.empty?

      xml['sf'].send(envoltorio) do
        facturas.each do |factura|
          xml['sf'].send(elemento) do
            factura.a_pares.each { |campo, valor| xml['sf'].send(campo, valor) }
          end
        end
      end
    end

    # Validaciones v1.2.2, ap. 3.1.3.1. La fecha se compara ya normalizada para
    # que dé igual si entró como Date o como cadena.
    def validar_fecha_expedicion!(original)
      fecha = original.is_a?(Date) ? original : Date.strptime(@fecha_expedicion, '%d-%m-%Y')

      if fecha < FECHA_MINIMA
        raise ArgumentError,
              "FechaExpedicionFactura no puede ser anterior a " \
              "#{FECHA_MINIMA.strftime('%d-%m-%Y')}, entrada en vigor de VERI*FACTU: " \
              "#{@fecha_expedicion}"
      end
      return unless fecha > Date.today

      raise ArgumentError,
            "FechaExpedicionFactura no puede ser futura: #{@fecha_expedicion}"
    end

    def validar_destinatarios!
      if TIPOS_CON_DESTINATARIO.include?(tipo_factura) && destinatarios.empty?
        raise ArgumentError,
              "TipoFactura #{tipo_factura} exige al menos un destinatario"
      end
      return unless TIPOS_SIN_DESTINATARIO.include?(tipo_factura) && !destinatarios.empty?

      raise ArgumentError,
            "TipoFactura #{tipo_factura} es simplificada y no admite destinatarios"
    end

    # Coherencia de las rectificativas. El XSD deja casi todo opcional, así que
    # estas reglas no las impone el esquema: sin ellas se puede montar un R1
    # sintácticamente válido que la AEAT rechaza con un error mucho menos claro.
    def validar_rectificativa!
      if rectificativa?
        if tipo_rectificativa.nil?
          raise ArgumentError,
                "TipoFactura #{tipo_factura} es rectificativa y exige " \
                "tipo_rectificativa: 'S' (sustitutiva) o 'I' (incremental)"
        end
        # facturas_rectificadas NO es obligatoria: la AEAT dice literalmente
        # "sólo podrá incluirse esta agrupación (no es obligatoria) si
        # TipoFactura es R1-R5" (Validaciones v1.2.2, ap. 3.1.3.4).
      else
        unless tipo_rectificativa.nil? && facturas_rectificadas.empty?
          raise ArgumentError,
                "TipoFactura #{tipo_factura} no es rectificativa: no admite " \
                'tipo_rectificativa ni facturas_rectificadas (usa R1-R5)'
        end
      end

      validar_importe_rectificacion!
      validar_limite(facturas_rectificadas, 'facturas_rectificadas')
    end

    # Una sustitutiva reexpresa el importe corregido completo, así que hay que
    # declarar cuál era el original. Una incremental ya ES la diferencia.
    def validar_importe_rectificacion!
      case tipo_rectificativa
      when 'S'
        if importe_rectificacion.nil?
          raise ArgumentError,
                'Una rectificativa por sustitución exige importe_rectificacion ' \
                'con la base y la cuota que se sustituyen'
        end
      when 'I'
        unless importe_rectificacion.nil?
          raise ArgumentError,
                'Una rectificativa incremental no lleva importe_rectificacion: ' \
                'sus propios importes ya son la diferencia'
        end
      end
    end

    # F3 es la factura emitida en sustitución de simplificadas. La agrupación
    # tampoco es obligatoria ahí, solo exclusiva de F3 (Validaciones v1.2.2,
    # ap. 3.1.3.5).
    def validar_sustitutiva!
      if tipo_factura != 'F3' && !facturas_sustituidas.empty?
        raise ArgumentError,
              "TipoFactura #{tipo_factura} no admite facturas_sustituidas (usa F3)"
      end

      validar_limite(facturas_sustituidas, 'facturas_sustituidas')
    end

    def validar_limite(facturas, campo)
      return if facturas.size <= MAXIMO_REFERENCIADAS

      raise ArgumentError,
            "#{campo} admite como mucho #{MAXIMO_REFERENCIADAS} facturas " \
            "(recibidas #{facturas.size})"
    end
  end

  # Registro de facturación de ANULACIÓN.
  class RegistroAnulacion
    attr_reader :id_emisor, :num_serie, :fecha_expedicion,
                :sistema_informatico, :fecha_hora_gen

    def initialize(id_emisor:, num_serie:, fecha_expedicion:,
                   sistema_informatico:, fecha_hora_gen:)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFacturaAnulada')
      @num_serie = Formato.num_serie(num_serie, 'NumSerieFacturaAnulada')
      @fecha_expedicion = Formato.fecha(fecha_expedicion)
      @sistema_informatico = sistema_informatico
      @fecha_hora_gen = Formato.marca_temporal(fecha_hora_gen)

      unless @sistema_informatico.is_a?(SistemaInformatico)
        raise ArgumentError, 'sistema_informatico debe ser VerifactuRails::SistemaInformatico'
      end
    end

    # Una anulación nunca puede iniciar la cadena, así que `anterior` es
    # obligatorio. Huella.anulacion ya lo exige; lo repetimos aquí para fallar
    # antes de construir nada.
    def huella(anterior:)
      Huella.anulacion(
        id_emisor: id_emisor, num_serie: num_serie,
        fecha_expedicion: fecha_expedicion, fecha_hora_gen: fecha_hora_gen,
        huella_anterior: anterior&.huella
      )
    end

    def construir(xml, anterior:)
      propia = huella(anterior: anterior)

      xml['sf'].RegistroAnulacion do
        xml['sf'].IDVersion IDVERSION
        xml['sf'].IDFactura do
          xml['sf'].IDEmisorFacturaAnulada id_emisor
          xml['sf'].NumSerieFacturaAnulada num_serie
          xml['sf'].FechaExpedicionFacturaAnulada fecha_expedicion
        end
        xml['sf'].Encadenamiento do
          xml['sf'].RegistroAnterior do
            anterior.a_pares.each { |campo, valor| xml['sf'].send(campo, valor) }
          end
        end
        xml['sf'].SistemaInformatico do
          sistema_informatico.a_pares.each { |campo, valor| xml['sf'].send(campo, valor) }
        end
        xml['sf'].FechaHoraHusoGenRegistro fecha_hora_gen
        xml['sf'].TipoHuella TIPO_HUELLA
        xml['sf'].Huella propia
      end
    end
  end
end
