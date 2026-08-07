# frozen_string_literal: true

module VerifactuRails
  module Libro
    # Una anotación del libro registro: un registro de facturación tal y como se
    # generó, con su sitio en la cadena.
    #
    # Es el SISTEMA DE REGISTRO, no una caché de lo que tiene la AEAT. Está
    # comprobado que la consulta de la AEAT devuelve una foto por factura y no el
    # histórico: los eslabones sustituidos desaparecen de allí. Si esta tabla se
    # pierde, el histórico de la cadena no existe en ninguna otra parte.
    class Registro < ActiveRecord::Base
      self.table_name = 'verifactu_registros'

      # Lo que define la posición en la cadena no se toca nunca más. El estado del
      # envío sí cambia; el encadenamiento no.
      attr_readonly :cadena_id, :tipo, :id_emisor, :num_serie, :fecha_expedicion,
                    :tipo_factura, :cuota_total, :importe_total,
                    :huella, :huella_anterior, :fecha_hora_gen, :payload,
                    :payload_version, :qr_url

      ESTADOS = %w[pendiente enviando anotado aceptado_con_errores rechazado].freeze

      belongs_to :cadena, class_name: 'VerifactuRails::Libro::Cadena'

      scope :pendientes, -> { where(estado: 'pendiente').order(:id) }
      scope :con_anomalias, -> { where.not(anomalias: nil) }

      def primero? = huella_anterior == ''
      def anomalias? = anomalias.present?

      def anomalias_lista
        anomalias.nil? ? [] : JSON.parse(anomalias).map(&:to_sym)
      end

      # El eslabón anterior, buscado por su huella. Funciona porque (cadena_id,
      # huella) es único.
      def anterior
        return nil if primero?

        cadena.registros.find_by(huella: huella_anterior)
      end

      # Para encadenar el siguiente.
      def a_registro_anterior
        RegistroAnterior.new(id_emisor: id_emisor, num_serie: num_serie,
                             fecha_expedicion: fecha_expedicion, huella: huella)
      end

      # La marca temporal tal y como entró en la huella, con su huso.
      def momento = Time.iso8601(fecha_hora_gen)

      # Recalcula la huella desde las columnas, sin tocar el payload ni volver a
      # construir el objeto de dominio. Es lo que permite detectar que alguien
      # editó la fila: si el recálculo no da lo almacenado, la anotación está
      # alterada.
      def huella_recalculada
        if tipo == 'anulacion'
          Huella.anulacion(id_emisor: id_emisor, num_serie: num_serie,
                           fecha_expedicion: fecha_expedicion,
                           fecha_hora_gen: fecha_hora_gen,
                           huella_anterior: huella_anterior)
        else
          Huella.alta(id_emisor: id_emisor, num_serie: num_serie,
                      fecha_expedicion: fecha_expedicion, tipo_factura: tipo_factura,
                      cuota_total: cuota_total, importe_total: importe_total,
                      fecha_hora_gen: fecha_hora_gen, huella_anterior: huella_anterior)
        end
      end

      def huella_cuadra? = huella_recalculada == huella
    end
  end
end
