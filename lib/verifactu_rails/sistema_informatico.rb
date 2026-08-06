# frozen_string_literal: true

require_relative 'formato'
require_relative 'error'

module VerifactuRails
  # Identificación del sistema informático de facturación, obligatoria en CADA
  # registro remitido (sf:SistemaInformaticoType).
  #
  # Ojo a lo que es esto realmente: la declaración de quién produce el SIF, en
  # cada envío. Los valores describen al SIF DESPLEGADO, no a esta gema, y los
  # aporta quien lo despliega. Esta librería es un componente del SIF, no el SIF.
  class SistemaInformatico
    # TipoUsoPosibleSoloVerifactu va fijo a 'S' y no se puede configurar.
    #
    # No es un capricho: declarar 'N' significa que el SIF puede operar en modo
    # NO VERI*FACTU, y eso obliga a llevar registro de eventos (RD 1007/2023;
    # FAQs Desarrolladores v1.3, ap. 15, nota 1). Esta gema no implementa
    # eventos, así que permitir 'N' sería dejar construir un sistema incompleto
    # sin avisar. Si necesitas 'N', esta no es la librería.
    SOLO_VERIFACTU = 'S'

    attr_reader :nombre_razon, :nif, :nombre_sistema, :id_sistema, :version,
                :numero_instalacion, :multi_ot, :multiples_ot

    # @param multi_ot [Boolean] TipoUsoPosibleMultiOT: si el SIF puede usarse
    #   para varios obligados tributarios.
    # @param multiples_ot [Boolean] IndicadorMultiplesOT: si de hecho se está
    #   usando para varios en este momento.
    def initialize(nombre_razon:, nif:, nombre_sistema:, id_sistema:, version:,
                   numero_instalacion:, multi_ot: false, multiples_ot: false)
      @nombre_razon = Formato.limitar(nombre_razon, 'NombreRazon', 120)
      @nif = Formato.nif(nif, 'NIF del productor')
      @nombre_sistema = Formato.limitar(nombre_sistema, 'NombreSistemaInformatico', 30)
      @id_sistema = validar_id_sistema(id_sistema)
      @version = Formato.limitar(version, 'Version', 50)
      @numero_instalacion = Formato.limitar(numero_instalacion, 'NumeroInstalacion', 100)
      # Por Formato.si_no y no por valor de verdad: 'N' es truthy en Ruby y se
      # emitía como 'S', invirtiendo lo que el usuario había declarado.
      @multi_ot = Formato.si_no(multi_ot, 'TipoUsoPosibleMultiOT') == 'S'
      @multiples_ot = Formato.si_no(multiples_ot, 'IndicadorMultiplesOT') == 'S'

      if @multiples_ot && !@multi_ot
        raise ValidacionError,
              'IndicadorMultiplesOT no puede ser cierto si TipoUsoPosibleMultiOT ' \
              'es falso: no puedes estar usándolo para varios obligados si el ' \
              'sistema declara que no lo admite'
      end
    end

    # Ap. 3.1.5: "deberá tener rellenas siempre las dos posiciones, cada una de
    # las cuales deberá ser una letra mayúscula, excepto la Ñ, o un dígito
    # numérico". El XSD solo limita la longitud a 2, así que sin esto pasaban
    # valores de una posición o en minúscula.
    PATRON_ID_SISTEMA = /\A[A-Z0-9]{2}\z/

    def solo_verifactu = SOLO_VERIFACTU
    def multi_ot? = @multi_ot
    def multiples_ot? = @multiples_ot

    # Orden EXACTO de sf:SistemaInformaticoType. Es una <sequence>: alterarlo
    # invalida el documento.
    def a_pares
      {
        'NombreRazon' => nombre_razon,
        'NIF' => nif,
        'NombreSistemaInformatico' => nombre_sistema,
        'IdSistemaInformatico' => id_sistema,
        'Version' => version,
        'NumeroInstalacion' => numero_instalacion,
        'TipoUsoPosibleSoloVerifactu' => SOLO_VERIFACTU,
        'TipoUsoPosibleMultiOT' => multi_ot ? 'S' : 'N',
        'IndicadorMultiplesOT' => multiples_ot ? 'S' : 'N'
      }
    end

    private

    def validar_id_sistema(valor)
      cadena = Formato.limitar(valor, 'IdSistemaInformatico', 2)
      return cadena if cadena.match?(PATRON_ID_SISTEMA)

      raise ValidacionError,
            'IdSistemaInformatico debe tener exactamente dos posiciones, cada una ' \
            "una letra mayúscula (salvo la Ñ) o un dígito: #{cadena.inspect}"
    end
  end
end
