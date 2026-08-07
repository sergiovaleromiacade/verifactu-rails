# frozen_string_literal: true

module VerifactuRails
  module Libro
    # Una cadena de registros: un "SIF virtual" identificado por su
    # NumeroInstalacion, con su obligado tributario.
    #
    # Las FAQs (v1.3) exigen que cada facturación distinta -sean de distintos
    # obligados o del mismo obligado en centros independientes, como tiendas-
    # lleve su propio nº de instalación, "porque se consideran SIF
    # independientes, como si fueran SIF virtuales".
    class Cadena < ActiveRecord::Base
      self.table_name = 'verifactu_cadenas'

      has_many :registros, class_name: 'VerifactuRails::Libro::Registro',
                           foreign_key: :cadena_id, inverse_of: :cadena, dependent: :restrict_with_error
      belongs_to :ultimo_registro, class_name: 'VerifactuRails::Libro::Registro',
                                   optional: true

      validates :numero_instalacion, :nif_obligado, :nombre_obligado, presence: true

      # Abre una cadena. El número de instalación se EXIGE explícito y no se
      # genera nunca aquí: ni con un default, ni con un find_or_create_by, ni
      # "por comodidad".
      #
      # No es celo: si la gema lo autogenerase, un contenedor que se recrea en
      # cada despliegue acabaría abriendo una instalación por despliegue, y en el
      # límite una por factura, que es exactamente el patrón que vacía de sentido
      # el encadenamiento. Abrir una instalación es un acto deliberado de quien
      # despliega y tiene que constar como tal.
      #
      # Las FAQs recomiendan como valor un timestamp de instalación o un
      # secuencial propio del obligado. No puede repetirse NUNCA, ni al reinstalar
      # el mismo software en la misma máquina.
      def self.abrir!(numero_instalacion:, nif_obligado:, nombre_obligado:)
        if numero_instalacion.to_s.strip.empty?
          raise ValidacionError,
                'numero_instalacion es obligatorio y no se genera solo. Usa un ' \
                'timestamp de instalación o un secuencial propio del obligado, y ' \
                'no lo reutilices jamás (FAQs Desarrolladores v1.3).'
        end

        create!(numero_instalacion: numero_instalacion,
                nif_obligado: Formato.nif(nif_obligado, 'NIF del obligado'),
                nombre_obligado: Formato.limitar(nombre_obligado, 'NombreRazon del obligado', 120))
      end

      # Anota un alta y la encadena. Síncrono y bajo lock: el encadenamiento no
      # se puede diferir, aunque el ENVÍO sí.
      def anotar_alta!(**datos)
        anotar!(RegistroAlta, 'alta', **datos)
      end

      def anotar_anulacion!(**datos)
        anotar!(RegistroAnulacion, 'anulacion', **datos)
      end

      def sistema_informatico = Libro.configuracion.sistema_para(self)

      private

      def anotar!(clase, tipo, **datos)
        with_lock do # SELECT ... FOR UPDATE sobre esta fila
          previo = ultimo_registro

          # Art. 7.i) de la OM. NO levanta excepción a propósito: ante una
          # anomalía de trazabilidad "la facturación NUNCA debe interrumpirse".
          anomalias = Autochequeo.new(previo).anomalias(ahora: Time.now)

          # Esto SÍ puede levantar: con datos inválidos no hay registro que
          # generar, y tampoco hay factura que emitir.
          registro = clase.new(**datos, sistema_informatico: sistema_informatico)

          anterior = previo&.a_registro_anterior
          fila = registros.create!(
            **columnas(registro, tipo),
            huella: registro.huella(anterior: anterior),
            huella_anterior: previo&.huella || '',
            payload: Libro.fragmento_xml(registro, anterior),
            qr_url: qr_de(registro, tipo),
            anomalias: anomalias.any? ? JSON.generate(anomalias) : nil
          )
          update!(ultimo_registro_id: fila.id)
          Libro.avisar_de(anomalias, fila) if anomalias.any?
          fila
        end
      end

      def columnas(registro, tipo)
        comunes = { tipo: tipo, id_emisor: registro.id_emisor,
                    num_serie: registro.num_serie,
                    fecha_expedicion: registro.fecha_expedicion,
                    fecha_hora_gen: registro.fecha_hora_gen }
        return comunes if tipo == 'anulacion'

        comunes.merge(tipo_factura: registro.tipo_factura,
                      cuota_total: registro.cuota_total,
                      importe_total: registro.importe_total)
      end

      # Una anulación no lleva QR propio: el QR va en la factura, y una anulación
      # no expide factura. Se guarda vacío para no dejar la columna nula.
      def qr_de(registro, tipo)
        return '' if tipo == 'anulacion'

        QR.url(registro, entorno: Libro.configuracion.entorno)
      end
    end
  end
end
