# frozen_string_literal: true

require_relative 'formato'
require_relative 'importe'
require_relative 'huella'
require_relative 'desglose'
require_relative 'sistema_informatico'
require_relative 'error'

module VerifactuRails
  IDVERSION = '1.0'   # sf:VersionType solo admite este valor
  TIPO_HUELLA = '01'  # sf:TipoHuellaType solo admite este valor

  # Espacios de nombres. Son URLs de www2 aunque los XSD se descarguen de
  # prewww2: el targetNamespace de los esquemas apunta a producción en ambos
  # entornos, y es el targetNamespace lo que manda.
  #
  # Los prefijos que se emiten son "sum" y "sum1", los mismos que usa la AEAT en
  # sus ejemplos de petición y los mismos que usa mybooking-es/verifactu-rb. Para
  # un parser XML el prefijo es irrelevante —lo que liga es el URI—, pero
  # coincidir permite comparar nuestra salida con los ejemplos oficiales línea a
  # línea cuando algo se rechaza, que es justo cuando menos ganas hay de traducir
  # prefijos mentalmente.
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
        raise ValidacionError,
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

  # Identificación de quien no tiene NIF español (sf:IDOtroType).
  #
  # Las reglas NO son las mismas según quién se identifique. Un destinatario
  # admite "no censado" (07) y desde España acepta 03 o 07; un tercero no admite
  # 07 en absoluto y desde España solo acepta 03 (Validaciones v1.2.2, ap. 12 y
  # 13). Por eso lo que varía entra por parámetro: duplicar el método era la vía
  # segura a que las dos copias se desincronizaran.
  module IdOtro
    # Lista L7 del Excel de diseños.
    TIPOS = %w[02 03 04 05 06 07].freeze

    # sf:CountryType2. Se toman del XSD, que es el contrato.
    PAISES = %w[
      AF AL DE AD AO AI AQ AG SA DZ AR AM AW AU AT AZ BS BH BD BB BE BZ BJ BM BY
      BO BA BW BV BR BN BG BF BI BT CV KY KH CM CA CF CC CO KM CG CD CK KP KR CI
      CR HR CU TD CZ CL CN CY CW DK DM DO EC EG AE ER SK SI ES US EE ET FO PH FI
      FJ FR GA GM GE GS GH GI GD GR GL GU GT GG GN GQ GW GY HT HM HN HK HU IN ID
      IR IQ IE IM IS IL IT JM JP JE JO KZ KE KG KI KW LA LS LV LB LR LY LI LT LU
      XG MO MK MG MY MW MV ML MT FK MP MA MH MU MR YT UM MX FM MD MC MN ME MS MZ
      MM NA NR CX NP NI NE NG NU NF NO NC NZ IO OM NL BQ PK PW PA PG PY PE PN PF
      PL PT PR QA GB RW RO RU RE SB SV WS AS KN SM SX PM VC SH LC ST SN RS SC SL
      SG SY SO LK SZ ZA SD SS SE CH SR TH TW TZ TJ PS TF TL TG TK TO TT TN TC TM
      TR TV UA UG UY UZ VU VA VE VN VG VI WF YE DJ ZM ZW QU XB XU XN
    ].freeze

    module_function

    # @param quien [String] para el mensaje de error
    # @param tipos_con_es [Array<String>] IDType admitidos si CodigoPais = "ES"
    # @param prohibidos [Array<String>] IDType que este bloque no admite nunca
    def normalizar(datos, quien:, tipos_con_es:, prohibidos: [])
      tipo = Formato.enumerado(datos.fetch(:id_type), 'IDType', TIPOS - prohibidos)
      pais = datos[:codigo_pais] && Formato.enumerado(datos[:codigo_pais], 'CodigoPais', PAISES)

      # "No censado" solo tiene sentido en España.
      if tipo == '07' && pais != 'ES'
        raise ValidacionError, "IDType=07 (no censado) exige CodigoPais='ES'"
      end
      if pais == 'ES' && !tipos_con_es.include?(tipo)
        raise ValidacionError,
              "Con CodigoPais='ES', el IDType de #{quien} solo puede ser " \
              "#{tipos_con_es.join(' o ')}"
      end
      # Con NIF-IVA (02) el país va implícito en el propio identificador.
      raise ValidacionError, "IDType=#{tipo} exige CodigoPais" if tipo != '02' && pais.nil?

      { 'CodigoPais' => pais, 'IDType' => tipo,
        'ID' => Formato.limitar(datos.fetch(:id), 'ID', 20) }.compact
    end
  end

  # Una persona identificada por NIF español O por identificación extranjera,
  # nunca las dos (sf:PersonaFisicaJuridicaType lo modela como <choice>).
  # Destinatario y Tercero comparten forma pero no reglas de identificación.
  class Persona
    attr_reader :nombre_razon, :nif, :id_otro

    # @param id_otro [Hash, nil] para no residentes:
    #   { codigo_pais: 'FR', id_type: '02', id: 'FR12345678901' }
    def initialize(nombre_razon:, nif: nil, id_otro: nil)
      if nif.nil? == id_otro.nil?
        raise ValidacionError,
              "Indica exactamente uno de nif: o id_otro: para #{self.class.quien}"
      end

      @nombre_razon = Formato.limitar(nombre_razon, 'NombreRazon', 120)
      @nif = nif && Formato.nif(nif, "NIF de #{self.class.quien}")
      @id_otro = id_otro && IdOtro.normalizar(id_otro, quien: self.class.quien,
                                                       tipos_con_es: self.class.tipos_con_es,
                                                       prohibidos: self.class.prohibidos)
    end

    def id_type = id_otro && id_otro['IDType']

    # Orden EXACTO de sf:PersonaFisicaJuridicaType.
    def a_pares
      pares = { 'NombreRazon' => nombre_razon }
      nif ? pares.merge('NIF' => nif) : pares.merge('IDOtro' => id_otro)
    end
  end

  # Un destinatario de la factura. Ap. 13: admite pasaporte (03) o no censado
  # (07) desde España; un residente español con NIF se identifica con NIF.
  class Destinatario < Persona
    def self.quien = 'un destinatario'
    def self.tipos_con_es = %w[03 07]
    def self.prohibidos = []
  end

  # El tercero que expide la factura o genera el registro. Ap. 12: aquí NO cabe
  # "no censado" y desde España solo pasaporte, a diferencia del destinatario.
  class Tercero < Persona
    def self.quien = 'un tercero'
    def self.tipos_con_es = %w[03]
    def self.prohibidos = %w[07]
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

    # RechazoPrevio en un ALTA admite tres valores (la anulación solo dos):
    #   N  no hubo rechazo previo de la AEAT
    #   S  lo hubo, y el registro sí existe en la AEAT
    #   X  el registro NO existe en la AEAT, se remitiera o no antes. Es la vía
    #      para subsanar algo que está en el SIF del obligado pero nunca llegó,
    #      típicamente al migrar desde NO VERI*FACTU.
    RECHAZOS_PREVIOS = %w[N S X].freeze

    # Destinatarios: obligatorio en unos tipos, prohibido en otros
    # (Validaciones v1.2.2, ap. 13). F2 y R5 son las simplificadas, donde por
    # definición no se identifica al destinatario.
    #
    # OJO al reutilizar esta lista: otras dos reglas coinciden con ella por
    # motivos distintos -el NIF-IVA de un destinatario (ap. 13) y la inversión
    # del sujeto pasivo (ap. 15.4) exigen los mismos tipos-, así que si la AEAT
    # cambia una sola de las tres habrá que separarlas.
    TIPOS_CON_DESTINATARIO = %w[F1 F3 R1 R2 R3 R4].freeze
    TIPOS_SIN_DESTINATARIO = %w[F2 R5].freeze

    # Ap. 11. Quién emitió la factura, si no fue el propio obligado.
    EMISORES = %w[D T].freeze # D = destinatario, T = tercero

    # Ap. 14. El cupón solo cabe en estos dos tipos.
    TIPOS_CON_CUPON = %w[R1 R5].freeze

    # Entrada en vigor de la Orden HAC/1177/2024.
    FECHA_MINIMA = Date.new(2024, 10, 28)

    # Ap. 15.8. Una factura simplificada (F2) no puede pasar de 3.000 €, sumando
    # base y cuota de todas las líneas del desglose. El margen lo concede la
    # propia AEAT.
    MAXIMO_SIMPLIFICADA = BigDecimal('3000.00')
    MARGEN_SIMPLIFICADA = BigDecimal('10.00')

    # Ap. 3.1.3.10. Obligatorio a partir de cien millones, en valor absoluto.
    UMBRAL_MACRODATO = BigDecimal('100000000.00')

    # Ap. 3.1.3.8 y 3.1.3.9: cada marca solo cabe en unos tipos de factura.
    TIPOS_SIMPLIFICADA_CUALIFICADA = %w[F1 F3 R1 R2 R3 R4].freeze
    TIPOS_SIN_IDENTIF_DESTINATARIO = %w[F2 R5].freeze

    # Ap. 15.6.4: los tipos que el grupo de entidades de nivel avanzado excluye.
    TIPOS_SIN_DESTINATARIO_NI_SUSTITUTIVA = %w[F2 F3 R5].freeze
    # Ap. 15.6.9.
    TIPOS_IVA_PENDIENTE_AAPP = %w[F1 R1 R2 R3 R4].freeze
    PREFIJOS_NIF_AAPP = %w[P Q S V].freeze

    attr_reader :id_emisor, :num_serie, :fecha_expedicion, :nombre_razon_emisor,
                :tipo_factura, :descripcion_operacion, :desglose, :cuota_total,
                :importe_total, :sistema_informatico, :fecha_hora_gen,
                :destinatarios, :fecha_operacion, :tipo_rectificativa,
                :facturas_rectificadas, :facturas_sustituidas,
                :importe_rectificacion, :subsanacion, :rechazo_previo,
                :simplificada_cualificada, :sin_identif_destinatario, :macrodato,
                :num_registro_acuerdo, :id_acuerdo_sistema, :emitida_por,
                :tercero, :cupon

    # @param subsanacion ['S', 'N', true, false, nil] marca el alta como
    #   subsanación de un registro ya generado. Es el ÚNICO mecanismo para
    #   corregir un registro que la AEAT aceptó con errores.
    # @param rechazo_previo ['N', 'S', 'X', nil] ver RECHAZOS_PREVIOS.
    def initialize(id_emisor:, num_serie:, fecha_expedicion:, nombre_razon_emisor:,
                   tipo_factura:, descripcion_operacion:, desglose:,
                   cuota_total:, importe_total:, sistema_informatico:,
                   fecha_hora_gen:, destinatarios: [], fecha_operacion: nil,
                   tipo_rectificativa: nil, facturas_rectificadas: [],
                   facturas_sustituidas: [], importe_rectificacion: nil,
                   subsanacion: nil, rechazo_previo: nil,
                   simplificada_cualificada: nil, sin_identif_destinatario: nil,
                   macrodato: nil, num_registro_acuerdo: nil, id_acuerdo_sistema: nil,
                   emitida_por: nil, tercero: nil, cupon: nil)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFactura')
      @num_serie = Formato.num_serie(num_serie)
      @fecha_expedicion = Formato.fecha(fecha_expedicion)
      @nombre_razon_emisor = Formato.limitar(nombre_razon_emisor, 'NombreRazonEmisor', 120)
      @tipo_factura = Formato.enumerado(tipo_factura, 'TipoFactura', TIPOS_FACTURA)
      @descripcion_operacion = Formato.limitar(descripcion_operacion, 'DescripcionOperacion', 500)
      @desglose = desglose.is_a?(Desglose) ? desglose : Desglose.new(desglose)
      @cuota_total = Importe.formatear(cuota_total)
      @importe_total = Importe.formatear(importe_total)
      @sistema_informatico = Formato.objeto(sistema_informatico, 'sistema_informatico',
                                            SistemaInformatico)
      @fecha_hora_gen = Formato.marca_temporal(fecha_hora_gen)
      @destinatarios = Formato.coleccion(destinatarios, 'destinatarios', Destinatario,
                                         maximo: MAXIMO_REFERENCIADAS)
      @fecha_operacion = fecha_operacion && Formato.fecha(fecha_operacion)
      @tipo_rectificativa = tipo_rectificativa &&
                            Formato.enumerado(tipo_rectificativa, 'TipoRectificativa', TIPOS_RECTIFICATIVA)
      @facturas_rectificadas = Formato.coleccion(facturas_rectificadas, 'facturas_rectificadas',
                                                 IdFactura, maximo: MAXIMO_REFERENCIADAS)
      @facturas_sustituidas = Formato.coleccion(facturas_sustituidas, 'facturas_sustituidas',
                                                IdFactura, maximo: MAXIMO_REFERENCIADAS)
      @importe_rectificacion = importe_rectificacion &&
                               Formato.objeto(importe_rectificacion, 'importe_rectificacion',
                                              ImporteRectificacion)
      @subsanacion = Formato.si_no(subsanacion, 'Subsanacion')
      @rechazo_previo = rechazo_previo &&
                        Formato.enumerado(rechazo_previo, 'RechazoPrevio', RECHAZOS_PREVIOS)
      @simplificada_cualificada = Formato.si_no(simplificada_cualificada, 'FacturaSimplificadaArt7273')
      @sin_identif_destinatario = Formato.si_no(sin_identif_destinatario,
                                                'FacturaSinIdentifDestinatarioArt61d')
      @macrodato = Formato.si_no(macrodato, 'Macrodato')
      @num_registro_acuerdo = num_registro_acuerdo &&
                              Formato.limitar(num_registro_acuerdo, 'NumRegistroAcuerdoFacturacion', 15)
      @id_acuerdo_sistema = id_acuerdo_sistema &&
                            Formato.limitar(id_acuerdo_sistema, 'IdAcuerdoSistemaInformatico', 16)
      @emitida_por = emitida_por &&
                     Formato.enumerado(emitida_por, 'EmitidaPorTerceroODestinatario', EMISORES)
      @tercero = tercero && Formato.objeto(tercero, 'tercero', Tercero)
      @cupon = Formato.si_no(cupon, 'Cupon')

      validar_fecha_expedicion!(fecha_expedicion)
      validar_subsanacion!
      validar_marcas!
      validar_macrodato!
      validar_limite_simplificada!
      validar_destinatarios!
      validar_rectificativa!
      validar_sustitutiva!
      validar_emisor_tercero!
      validar_cupon!
      validar_desglose_cruzado!
    end

    # FechaOperacion, y la de expedición si aquella no se informa. Es la fecha
    # contra la que la AEAT mide las ventanas temporales de tipos y recargos
    # (Validaciones v1.2.2, ap. 15.1 y 15.3).
    def fecha_referencia
      Date.strptime(fecha_operacion || fecha_expedicion, '%d-%m-%Y')
    end

    def rectificativa? = tipo_factura.start_with?('R')

    # Huella de este registro. `anterior` es nil solo en el primer registro de la
    # cadena de ese SIF y NIF obligado (una sola cadena, no una por serie).
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

      xml['sum1'].RegistroAlta do
        xml['sum1'].IDVersion IDVERSION
        xml['sum1'].IDFactura do
          xml['sum1'].IDEmisorFactura id_emisor
          xml['sum1'].NumSerieFactura num_serie
          xml['sum1'].FechaExpedicionFactura fecha_expedicion
        end
        xml['sum1'].NombreRazonEmisor nombre_razon_emisor
        xml['sum1'].Subsanacion subsanacion if subsanacion
        xml['sum1'].RechazoPrevio rechazo_previo if rechazo_previo
        xml['sum1'].TipoFactura tipo_factura
        xml['sum1'].TipoRectificativa tipo_rectificativa if tipo_rectificativa
        construir_referenciadas(xml, 'FacturasRectificadas', 'IDFacturaRectificada',
                                facturas_rectificadas)
        construir_referenciadas(xml, 'FacturasSustituidas', 'IDFacturaSustituida',
                                facturas_sustituidas)
        if importe_rectificacion
          xml['sum1'].ImporteRectificacion do
            importe_rectificacion.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
          end
        end
        xml['sum1'].FechaOperacion fecha_operacion if fecha_operacion
        xml['sum1'].DescripcionOperacion descripcion_operacion
        xml['sum1'].FacturaSimplificadaArt7273 simplificada_cualificada if simplificada_cualificada
        if sin_identif_destinatario
          xml['sum1'].FacturaSinIdentifDestinatarioArt61d sin_identif_destinatario
        end
        xml['sum1'].Macrodato macrodato if macrodato
        xml['sum1'].EmitidaPorTerceroODestinatario emitida_por if emitida_por
        xml['sum1'].Tercero { construir_persona(xml, tercero) } if tercero
        construir_destinatarios(xml)
        xml['sum1'].Cupon cupon if cupon
        construir_desglose(xml)
        xml['sum1'].CuotaTotal cuota_total
        xml['sum1'].ImporteTotal importe_total
        construir_encadenamiento(xml, anterior)
        construir_sistema(xml)
        xml['sum1'].FechaHoraHusoGenRegistro fecha_hora_gen
        xml['sum1'].NumRegistroAcuerdoFacturacion num_registro_acuerdo if num_registro_acuerdo
        xml['sum1'].IdAcuerdoSistemaInformatico id_acuerdo_sistema if id_acuerdo_sistema
        xml['sum1'].TipoHuella TIPO_HUELLA
        xml['sum1'].Huella propia
      end
    end

    private

    def construir_destinatarios(xml)
      return if destinatarios.empty?

      xml['sum1'].Destinatarios do
        destinatarios.each do |d|
          xml['sum1'].IDDestinatario { construir_persona(xml, d) }
        end
      end
    end

    # sf:PersonaFisicaJuridicaType. Lo comparten Destinatario y Tercero, que
    # tienen la misma forma aunque no las mismas reglas de identificación.
    def construir_persona(xml, persona)
      xml['sum1'].NombreRazon persona.nombre_razon
      if persona.nif
        xml['sum1'].NIF persona.nif
      else
        xml['sum1'].IDOtro { persona.id_otro.each { |k, v| xml['sum1'].send(k, v) } }
      end
    end

    def construir_desglose(xml)
      xml['sum1'].Desglose do
        desglose.detalles.each do |detalle|
          xml['sum1'].DetalleDesglose do
            detalle.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
          end
        end
      end
    end

    def construir_encadenamiento(xml, anterior)
      xml['sum1'].Encadenamiento do
        if anterior.nil?
          xml['sum1'].PrimerRegistro 'S'
        else
          xml['sum1'].RegistroAnterior do
            anterior.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
          end
        end
      end
    end

    def construir_sistema(xml)
      xml['sum1'].SistemaInformatico do
        sistema_informatico.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
      end
    end

    def construir_referenciadas(xml, envoltorio, elemento, facturas)
      return if facturas.empty?

      xml['sum1'].send(envoltorio) do
        facturas.each do |factura|
          xml['sum1'].send(elemento) do
            factura.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
          end
        end
      end
    end

    # Validaciones v1.2.2, ap. 3.1.3.1. La fecha se compara ya normalizada para
    # que dé igual si entró como Date o como cadena.
    def validar_fecha_expedicion!(_original)
      # Se reparsea SIEMPRE la fecha ya normalizada, en vez de mirar el objeto
      # original. Con `original.is_a?(Date)` un DateTime entraba con su hora
      # puesta, y como Date.today es medianoche, `DateTime.now > Date.today` es
      # cierto: se rechazaba como "futura" una factura de hoy. Time no lo sufría
      # porque no es un Date, así que la asimetría además era invisible.
      fecha = Date.strptime(@fecha_expedicion, '%d-%m-%Y')

      if fecha < FECHA_MINIMA
        raise ValidacionError,
              "FechaExpedicionFactura no puede ser anterior a " \
              "#{FECHA_MINIMA.strftime('%d-%m-%Y')}, entrada en vigor de VERI*FACTU: " \
              "#{@fecha_expedicion}"
      end
      return unless fecha > Date.today

      raise ValidacionError,
            "FechaExpedicionFactura no puede ser futura: #{@fecha_expedicion}"
    end

    # Ap. 3.1.3.2. Un RechazoPrevio distinto de "N" solo tiene sentido dentro de
    # una subsanación: las combinaciones (Subsanacion=N, RechazoPrevio=S) y
    # (Subsanacion=N, RechazoPrevio=X) no se admiten (lista L17).
    def validar_subsanacion!
      return if rechazo_previo.nil? || rechazo_previo == 'N'
      return if subsanacion == 'S'

      raise ValidacionError,
            "RechazoPrevio=#{rechazo_previo} exige subsanacion: 'S'. " \
            'Un rechazo previo solo se declara al subsanar el registro rechazado.'
    end

    # Ap. 3.1.3.8 y 3.1.3.9: cada marca solo cabe en su familia de tipos.
    def validar_marcas!
      if simplificada_cualificada && !TIPOS_SIMPLIFICADA_CUALIFICADA.include?(tipo_factura)
        raise ValidacionError,
              "FacturaSimplificadaArt7273 no cabe con TipoFactura #{tipo_factura} " \
              "(solo #{TIPOS_SIMPLIFICADA_CUALIFICADA.join(', ')})"
      end
      return unless sin_identif_destinatario && !TIPOS_SIN_IDENTIF_DESTINATARIO.include?(tipo_factura)

      raise ValidacionError,
            "FacturaSinIdentifDestinatarioArt61d no cabe con TipoFactura #{tipo_factura} " \
            "(solo #{TIPOS_SIN_IDENTIF_DESTINATARIO.join(', ')})"
    end

    # Ap. 3.1.3.10. Se comprueba en valor absoluto: una rectificativa negativa de
    # cien millones es igual de macrodato que la factura que corrige.
    def validar_macrodato!
      supera = BigDecimal(importe_total).abs >= UMBRAL_MACRODATO
      return if supera == (macrodato == 'S')

      if supera
        raise ValidacionError,
              "ImporteTotal #{importe_total} alcanza el umbral de macrodato: " \
              "exige macrodato: 'S'"
      end

      raise ValidacionError,
            "macrodato: 'S' exige un ImporteTotal de al menos " \
            "#{UMBRAL_MACRODATO.to_s('F')} en valor absoluto (#{importe_total})"
    end

    # Ap. 15.8. El tope de las simplificadas se mide sobre el desglose, no sobre
    # ImporteTotal, y decae si hay acuerdo de facturación o si la factura se
    # acoge al art. 6.1.d) del RD 1619/2012.
    def validar_limite_simplificada!
      return unless tipo_factura == 'F2'
      return if num_registro_acuerdo || sin_identif_destinatario == 'S'

      suma = desglose.detalles.sum do |d|
        BigDecimal(d.base_imponible) + BigDecimal(d.cuota_repercutida || '0')
      end
      return if suma <= MAXIMO_SIMPLIFICADA + MARGEN_SIMPLIFICADA

      raise ValidacionError,
            "Una factura simplificada (F2) no puede superar #{MAXIMO_SIMPLIFICADA.to_s('F')} " \
            "sumando base y cuota del desglose (suma: #{Importe.formatear(suma)}). " \
            'Si hay acuerdo de facturación indica num_registro_acuerdo:, y si se ' \
            "acoge al art. 6.1.d) indica sin_identif_destinatario: 'S'."
    end

    def validar_destinatarios!
      if TIPOS_CON_DESTINATARIO.include?(tipo_factura) && destinatarios.empty?
        raise ValidacionError,
              "TipoFactura #{tipo_factura} exige al menos un destinatario"
      end
      return unless TIPOS_SIN_DESTINATARIO.include?(tipo_factura) && !destinatarios.empty?

      raise ValidacionError,
            "TipoFactura #{tipo_factura} es simplificada y no admite destinatarios"
    end

    # NO se implementa la última regla del ap. 13 ("si un destinatario se
    # identifica por IDOtro con IDType=02, TipoFactura debe ser F1/F3/R1-R4")
    # porque es REDUNDANTE con las dos de arriba: los ocho tipos de factura se
    # reparten entre los que exigen destinatario (F1, F3, R1-R4) y los que lo
    # prohíben (F2, R5), así que si hay un destinatario el tipo ya está en esa
    # lista, se identifique como se identifique. Añadir el código habría dejado
    # una comprobación que no puede fallar nunca: parece que cubre algo y no
    # cubre nada.

    # Ap. 11 y 12. Quién emitió la factura y el bloque Tercero se condicionan
    # mutuamente, en las dos direcciones.
    def validar_emisor_tercero!
      if emitida_por == 'T' && tercero.nil?
        raise ValidacionError,
              "emitida_por: 'T' exige el bloque tercero: con quien expidió la factura"
      end
      if emitida_por == 'D' && destinatarios.empty?
        raise ValidacionError,
              "emitida_por: 'D' exige destinatarios: la emitió el destinatario, " \
              'así que hay que identificarlo'
      end
      if tercero && emitida_por != 'T'
        raise ValidacionError,
              "tercero: solo cabe con emitida_por: 'T' (recibido: #{emitida_por.inspect})"
      end
      return unless tercero&.nif == id_emisor

      raise ValidacionError,
            "El NIF del tercero (#{tercero.nif}) no puede ser el del emisor: si " \
            'la factura la expide el propio obligado, no hay tercero que declarar'
    end

    # Ap. 14. La norma dice "sólo se podrá rellenar con S", así que un 'N'
    # explícito no es un valor válido: es un campo que sobra.
    def validar_cupon!
      return if cupon.nil?

      if cupon == 'N'
        raise ValidacionError,
              "Cupon solo admite 'S'; si la factura no lleva cupón, omite el campo"
      end
      return if TIPOS_CON_CUPON.include?(tipo_factura)

      raise ValidacionError,
            "Cupon solo cabe con TipoFactura #{TIPOS_CON_CUPON.join(' o ')} " \
            "(recibido #{tipo_factura})"
    end

    # Reglas que cruzan el desglose con datos del registro. Un Detalle aislado no
    # conoce ni el TipoFactura ni la fecha de la operación, así que estas no
    # pueden vivir en Detalle por mucho que hablen del desglose.
    def validar_desglose_cruzado!
      validar_inversion_sujeto_pasivo!
      validar_grupo_entidades!
      validar_cobro_por_cuenta_de_terceros!
      validar_iva_pendiente_aapp!
      desglose.detalles.each { |d| d.validar_en_fecha!(fecha_referencia) }
    end

    # Las claves de régimen cuyas reglas (ap. 15.6.4, 15.6.7 y 15.6.9) miran
    # fuera de la línea. El resto de la 15.6 vive en Detalle.
    #
    # Igual que allí, solo cuentan las líneas de IVA o IGIC: la norma acota estas
    # reglas a "Impuesto = 01, 03 o no se cumplimenta".
    def usa_regimen?(clave)
      desglose.detalles.any? do |d|
        d.clave_regimen == clave && (d.iva? || d.impuesto == '03')
      end
    end

    # Ap. 15.6.4. La segunda condición no se puede cumplir: exige
    # BaseImponibleACoste, que esta gema no emite. Se para aquí en vez de armar
    # un registro que la AEAT va a rechazar, y el mensaje dice por qué.
    def validar_grupo_entidades!
      return unless usa_regimen?('06')

      if TIPOS_SIN_DESTINATARIO_NI_SUSTITUTIVA.include?(tipo_factura)
        raise ValidacionError,
              'ClaveRegimen 06 (grupo de entidades, nivel avanzado) no cabe con ' \
              "TipoFactura #{tipo_factura}: la norma excluye " \
              "#{TIPOS_SIN_DESTINATARIO_NI_SUSTITUTIVA.join(', ')}"
      end

      raise ValidacionError,
            'ClaveRegimen 06 (grupo de entidades, nivel avanzado) exige ' \
            'BaseImponibleACoste, un campo que esta gema todavía no emite. Un ' \
            'registro así lo rechazaría la AEAT, así que no se construye.'
    end

    # Ap. 15.6.7. La calificación N1 la exige Detalle; aquí van las dos
    # condiciones que necesitan la cabecera.
    def validar_cobro_por_cuenta_de_terceros!
      return unless usa_regimen?('10')

      unless tipo_factura == 'F1'
        raise ValidacionError,
              'ClaveRegimen 10 (cobro por cuenta de terceros) exige TipoFactura ' \
              "F1, no #{tipo_factura}"
      end
      return if Array(destinatarios).all?(&:nif)

      raise ValidacionError,
            'ClaveRegimen 10 (cobro por cuenta de terceros) exige que TODOS los ' \
            'destinatarios se identifiquen por NIF, no por IDOtro'
    end

    # Ap. 15.6.9. El NIF de una Administración Pública empieza por P, Q, S o V,
    # y la norma lo exige explícitamente aquí.
    def validar_iva_pendiente_aapp!
      return unless usa_regimen?('14')

      unless TIPOS_IVA_PENDIENTE_AAPP.include?(tipo_factura)
        raise ValidacionError,
              'ClaveRegimen 14 (IVA pendiente de devengo, AAPP) exige TipoFactura ' \
              "#{TIPOS_IVA_PENDIENTE_AAPP.join(', ')}, no #{tipo_factura}"
      end
      validar_fecha_operacion_aapp!
      return if Array(destinatarios).all? { |d| d.nif && PREFIJOS_NIF_AAPP.include?(d.nif[0]) }

      raise ValidacionError,
            'ClaveRegimen 14 (IVA pendiente de devengo, AAPP) exige que todos los ' \
            "destinatarios lleven NIF y empiece por #{PREFIJOS_NIF_AAPP.join(', ')}"
    end

    def validar_fecha_operacion_aapp!
      if fecha_operacion.nil?
        raise ValidacionError,
              'ClaveRegimen 14 (IVA pendiente de devengo, AAPP) exige FechaOperacion'
      end
      return if Date.strptime(fecha_operacion, '%d-%m-%Y') >
                Date.strptime(fecha_expedicion, '%d-%m-%Y')

      raise ValidacionError,
            'ClaveRegimen 14 (IVA pendiente de devengo, AAPP) exige que ' \
            "FechaOperacion (#{fecha_operacion}) sea posterior a la de " \
            "expedición (#{fecha_expedicion})"
    end

    # Ap. 15.4, primera regla. Coincide en lista con TIPOS_CON_DESTINATARIO pero
    # es otra regla: aquí lo que no cabe es repercutir por inversión del sujeto
    # pasivo en una simplificada.
    def validar_inversion_sujeto_pasivo!
      return unless desglose.detalles.any? { |d| d.calificacion == 'S2' }
      return if TIPOS_CON_DESTINATARIO.include?(tipo_factura)

      raise ValidacionError,
            "CalificacionOperacion S2 (inversión del sujeto pasivo) no cabe con " \
            "TipoFactura #{tipo_factura}: solo #{TIPOS_CON_DESTINATARIO.join(', ')}"
    end

    # Coherencia de las rectificativas. El XSD deja casi todo opcional, así que
    # estas reglas no las impone el esquema: sin ellas se puede montar un R1
    # sintácticamente válido que la AEAT rechaza con un error mucho menos claro.
    def validar_rectificativa!
      if rectificativa?
        if tipo_rectificativa.nil?
          raise ValidacionError,
                "TipoFactura #{tipo_factura} es rectificativa y exige " \
                "tipo_rectificativa: 'S' (sustitutiva) o 'I' (incremental)"
        end
        # facturas_rectificadas NO es obligatoria: la AEAT dice literalmente
        # "sólo podrá incluirse esta agrupación (no es obligatoria) si
        # TipoFactura es R1-R5" (Validaciones v1.2.2, ap. 3.1.3.4).
      else
        unless tipo_rectificativa.nil? && facturas_rectificadas.empty?
          raise ValidacionError,
                "TipoFactura #{tipo_factura} no es rectificativa: no admite " \
                'tipo_rectificativa ni facturas_rectificadas (usa R1-R5)'
        end
      end

      validar_importe_rectificacion!
    end

    # Una sustitutiva reexpresa el importe corregido completo, así que hay que
    # declarar cuál era el original. Una incremental ya ES la diferencia.
    # "Sólo deberá incluirse esta agrupación si el campo TipoRectificativa = 'S'.
    #  Obligatorio si TipoRectificativa = 'S'." (Validaciones v1.2.2, ap. 3.1.3.6)
    #
    # Las dos direcciones, y "sólo si S" incluye el caso en que TipoRectificativa
    # ni siquiera existe: una F1 con ImporteRectificacion también lo incumple.
    def validar_importe_rectificacion!
      if tipo_rectificativa == 'S'
        return unless importe_rectificacion.nil?

        raise ValidacionError,
              'Una rectificativa por sustitución exige importe_rectificacion ' \
              'con la base y la cuota que se sustituyen'
      end

      return if importe_rectificacion.nil?

      raise ValidacionError,
            if tipo_rectificativa == 'I'
              'Una rectificativa incremental no lleva importe_rectificacion: ' \
              'sus propios importes ya son la diferencia'
            else
              "TipoFactura #{tipo_factura} no admite importe_rectificacion: " \
              "la AEAT solo lo permite con TipoRectificativa='S'"
            end
    end

    # F3 es la factura emitida en sustitución de simplificadas. La agrupación
    # tampoco es obligatoria ahí, solo exclusiva de F3 (Validaciones v1.2.2,
    # ap. 3.1.3.5).
    def validar_sustitutiva!
      if tipo_factura != 'F3' && !facturas_sustituidas.empty?
        raise ValidacionError,
              "TipoFactura #{tipo_factura} no admite facturas_sustituidas (usa F3)"
      end
    end
  end

  # Registro de facturación de ANULACIÓN.
  class RegistroAnulacion
    # A diferencia del alta, aquí RechazoPrevio NO admite "X": ese valor existe
    # para subsanar altas que no constan en la AEAT, y una anulación de algo que
    # no consta se expresa con SinRegistroPrevio.
    RECHAZOS_PREVIOS = %w[N S].freeze

    attr_reader :id_emisor, :num_serie, :fecha_expedicion,
                :sistema_informatico, :fecha_hora_gen,
                :sin_registro_previo, :rechazo_previo

    # @param sin_registro_previo ['S', 'N', true, false, nil] la factura que se
    #   anula no consta en la AEAT (p. ej. se facturó en NO VERI*FACTU).
    # @param rechazo_previo ['S', 'N', nil] la AEAT rechazó una anulación previa.
    def initialize(id_emisor:, num_serie:, fecha_expedicion:,
                   sistema_informatico:, fecha_hora_gen:,
                   sin_registro_previo: nil, rechazo_previo: nil)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFacturaAnulada')
      @num_serie = Formato.num_serie(num_serie, 'NumSerieFacturaAnulada')
      @fecha_expedicion = Formato.fecha(fecha_expedicion)
      @sistema_informatico = Formato.objeto(sistema_informatico, 'sistema_informatico',
                                            SistemaInformatico)
      @fecha_hora_gen = Formato.marca_temporal(fecha_hora_gen)
      @sin_registro_previo = Formato.si_no(sin_registro_previo, 'SinRegistroPrevio')
      @rechazo_previo = rechazo_previo &&
                        Formato.enumerado(rechazo_previo, 'RechazoPrevio', RECHAZOS_PREVIOS)
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

      xml['sum1'].RegistroAnulacion do
        xml['sum1'].IDVersion IDVERSION
        xml['sum1'].IDFactura do
          xml['sum1'].IDEmisorFacturaAnulada id_emisor
          xml['sum1'].NumSerieFacturaAnulada num_serie
          xml['sum1'].FechaExpedicionFacturaAnulada fecha_expedicion
        end
        xml['sum1'].SinRegistroPrevio sin_registro_previo if sin_registro_previo
        xml['sum1'].RechazoPrevio rechazo_previo if rechazo_previo
        xml['sum1'].Encadenamiento do
          xml['sum1'].RegistroAnterior do
            anterior.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
          end
        end
        xml['sum1'].SistemaInformatico do
          sistema_informatico.a_pares.each { |campo, valor| xml['sum1'].send(campo, valor) }
        end
        xml['sum1'].FechaHoraHusoGenRegistro fecha_hora_gen
        xml['sum1'].TipoHuella TIPO_HUELLA
        xml['sum1'].Huella propia
      end
    end
  end
end
