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
      @num_serie = Formato.limitar(num_serie, 'NumSerieFactura anterior', 60)
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

    attr_reader :id_emisor, :num_serie, :fecha_expedicion, :nombre_razon_emisor,
                :tipo_factura, :descripcion_operacion, :desglose, :cuota_total,
                :importe_total, :sistema_informatico, :fecha_hora_gen,
                :destinatarios, :fecha_operacion

    def initialize(id_emisor:, num_serie:, fecha_expedicion:, nombre_razon_emisor:,
                   tipo_factura:, descripcion_operacion:, desglose:,
                   cuota_total:, importe_total:, sistema_informatico:,
                   fecha_hora_gen:, destinatarios: [], fecha_operacion: nil)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFactura')
      @num_serie = Formato.limitar(num_serie, 'NumSerieFactura', 60)
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

      unless @sistema_informatico.is_a?(SistemaInformatico)
        raise ArgumentError, 'sistema_informatico debe ser VerifactuRails::SistemaInformatico'
      end
      if @destinatarios.size > 1000
        raise ArgumentError, 'Como mucho 1000 destinatarios por registro'
      end

      avisar_rectificativa!
    end

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

    # Las rectificativas exigen TipoRectificativa y FacturasRectificadas, que
    # todavía no emitimos. Fallar aquí es preferible a mandar un R1 incompleto y
    # que lo rechace la AEAT con un error mucho menos claro.
    def avisar_rectificativa!
      return unless tipo_factura.start_with?('R')

      raise NotImplementedError,
            "TipoFactura #{tipo_factura} (rectificativa) todavía no está " \
            'implementado: falta emitir TipoRectificativa y FacturasRectificadas.'
    end
  end

  # Registro de facturación de ANULACIÓN.
  class RegistroAnulacion
    attr_reader :id_emisor, :num_serie, :fecha_expedicion,
                :sistema_informatico, :fecha_hora_gen

    def initialize(id_emisor:, num_serie:, fecha_expedicion:,
                   sistema_informatico:, fecha_hora_gen:)
      @id_emisor = Formato.nif(id_emisor, 'IDEmisorFacturaAnulada')
      @num_serie = Formato.limitar(num_serie, 'NumSerieFacturaAnulada', 60)
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
