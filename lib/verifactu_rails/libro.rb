# frozen_string_literal: true

require 'json'

begin
  require 'active_record'
rescue LoadError
  raise LoadError, <<~TXT
    verifactu_rails/libro necesita ActiveRecord y no se ha podido cargar.

    La gema lo declara como dependencia, así que esto suele significar un bundle
    a medias o que se ha copiado lib/ a mano. Con `bundle install` debería bastar.

    Si lo que quieres es solo calcular huellas y generar XML, no cargues esta
    capa: `require 'verifactu-rails'` no necesita ActiveRecord para nada.
  TXT
end

require_relative '../verifactu-rails'

module VerifactuRails
  # El libro registro: la capa de persistencia.
  #
  # Se carga APARTE del núcleo (`require 'verifactu_rails/libro'`), porque exige
  # ActiveRecord y el núcleo no depende de Rails. Quien solo quiera generar XML y
  # huellas no arrastra nada de esto.
  #
  # POR QUÉ ESTA CAPA EXISTE. No es una caché de lo que tiene la AEAT: es el
  # sistema de registro. Está comprobado que la consulta de la AEAT devuelve una
  # foto por factura, no el histórico, así que los eslabones sustituidos por una
  # subsanación desaparecen de allí. El histórico de la cadena no existe en
  # ninguna otra parte.
  module Libro
    # Lo que identifica al SOFTWARE. Lo que identifica a la INSTALACIÓN
    # (NumeroInstalacion) y al obligado va en la tabla de cadenas, no aquí: hay
    # una instalación por fuente de facturación, no una por despliegue.
    Configuracion = Struct.new(:productor_nombre, :productor_nif, :nombre_sistema,
                               :id_sistema, :version, :multi_ot, :multiples_ot,
                               :entorno, :al_detectar_anomalia,
                               keyword_init: true) do
      def sistema_para(cadena)
        SistemaInformatico.new(
          nombre_razon: productor_nombre, nif: productor_nif,
          nombre_sistema: nombre_sistema, id_sistema: id_sistema, version: version,
          numero_instalacion: cadena.numero_instalacion,
          multi_ot: multi_ot || false, multiples_ot: multiples_ot || false
        )
      end
    end

    class << self
      def configuracion
        @configuracion ||= Configuracion.new(entorno: :pruebas)
      end

      def configure = yield(configuracion)

      # El fragmento XML del registro, ya construido y con su huella dentro. Se
      # guarda hecho para que lo que se envíe sea exactamente lo que se calculó:
      # si nadie vuelve a derivarlo, la huella y el XML no pueden divergir.
      #
      # Los namespaces se declaran en el propio fragmento aunque luego se anide
      # dentro del envío, que los repite: es redundante pero válido, y hace que
      # cada fragmento se pueda leer y validar por separado.
      def fragmento_xml(registro, anterior)
        constructor = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
          xml['sum'].RegistroFactura('xmlns:sum' => NS_LR, 'xmlns:sum1' => NS_SF) do
            registro.construir(xml, anterior: anterior)
          end
        end
        constructor.doc.root.to_xml
      end

      # Las anomalías del art. 7.i no interrumpen la facturación, pero tienen que
      # llegar a alguien. Por defecto no se hace nada: quien despliega decide si
      # las manda a un log, a Sentry o a un panel.
      def avisar_de(anomalias, registro)
        configuracion.al_detectar_anomalia&.call(anomalias, registro)
      end
    end
  end
end

require_relative 'libro/migracion'
require_relative 'libro/cadena'
require_relative 'libro/registro'
require_relative 'libro/autochequeo'
require_relative 'libro/remesa'
require_relative 'libro/reconciliacion'
