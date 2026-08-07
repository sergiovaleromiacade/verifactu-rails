# frozen_string_literal: true

module VerifactuRails
  module Libro
    # Remisión a la AEAT de los registros que una cadena tiene pendientes.
    #
    # Va SEPARADO de anotar! a propósito. El encadenamiento es síncrono y bajo
    # lock porque no se puede diferir; el envío es asíncrono y reintentable
    # porque sí. Confundir las dos cosas es lo que llevaría a bloquear una venta
    # porque la AEAT no responde.
    #
    # Sobre el tamaño del lote: agrupar NO es el modo normal. Las FAQs exigen que
    # la remisión sea "inmediata o sin demora apreciable" a la expedición, así que
    # un comercio que factura cada diez minutos mandará siempre un registro por
    # petición. El tope de 1000 es un techo para quien factura rápido, y el lote
    # acaba siendo del tamaño que dicte el ritmo de facturación, no una decisión.
    class Remesa
      MAXIMO = Envio::MAXIMO_REGISTROS

      # Se envían también los que quedaron 'enviando': si un envío dio timeout no
      # se sabe si llegó, y reintentar es seguro porque un duplicado se trata como
      # éxito. Dejarlos fuera los abandonaría para siempre.
      ENVIABLES = %w[pendiente enviando].freeze

      Resultado = Struct.new(:estado, :respuesta, :enviados, keyword_init: true) do
        def enviado? = estado == :enviado
      end

      def initialize(cadena, transporte:)
        @cadena = cadena
        @transporte = transporte
      end

      # @return [Resultado] con estado :enviado, :esperando, :nada_pendiente o
      #   :bloqueada_por_rechazo
      def enviar!(ahora: Time.now)
        return sin_enviar(:esperando) if esperando?(ahora)
        return sin_enviar(:bloqueada_por_rechazo) if rechazo_sin_resolver?

        lote = cadena.registros.where(estado: ENVIABLES).order(:id).limit(MAXIMO).to_a
        return sin_enviar(:nada_pendiente) if lote.empty?

        marcar_enviando(lote)
        respuesta = transmitir(lote)
        aplicar!(lote, respuesta)
        cadena.update!(no_enviar_antes_de: ahora + respuesta.tiempo_espera.to_i)

        Resultado.new(estado: :enviado, respuesta: respuesta, enviados: lote)
      end

      private

      attr_reader :cadena, :transporte

      def sin_enviar(estado) = Resultado.new(estado: estado, enviados: [])

      def esperando?(ahora)
        cadena.no_enviar_antes_de.present? && cadena.no_enviar_antes_de > ahora
      end

      # Un registro rechazado NO consta en la AEAT, así que todo lo que encadena
      # detrás apunta a un eslabón que allí no existe. Seguir enviando funcionaría
      # -está comprobado que la AEAT no valida el eslabón al recibir- y dejaría una
      # cadena incoherente aceptada en silencio. Se para y se avisa: resolver un
      # rechazo es una decisión de negocio, no algo que un job deba improvisar.
      def rechazo_sin_resolver?
        cadena.registros.exists?(estado: 'rechazado')
      end

      def marcar_enviando(lote)
        cadena.registros.where(id: lote.map(&:id)).update_all(estado: 'enviando')
      end

      def transmitir(lote)
        xml = Envio.xml_desde_fragmentos(
          nif_obligado: cadena.nif_obligado, nombre_obligado: cadena.nombre_obligado,
          fragmentos: lote.map(&:payload)
        )
        Respuesta.new(transporte.enviar(xml).fetch(:cuerpo))
      end

      def aplicar!(lote, respuesta)
        por_serie = respuesta.lineas.group_by(&:num_serie)
        lote.each do |fila|
          linea = por_serie[fila.num_serie]&.shift
          next if linea.nil? # sin veredicto: se queda 'enviando' y se reintenta

          fila.update!(estado: estado_de(linea), csv: respuesta.csv,
                       codigo_error: linea.codigo_error,
                       descripcion_error: descripcion_de(linea),
                       enviado_at: Time.now)
        end
      end

      # Un duplicado es un ÉXITO, no un fallo: significa que el registro ya consta
      # en la AEAT, que es justo lo que se quería. Pasa al reintentar un envío que
      # dio timeout. La validación local de numeración hace que un choque real no
      # pueda existir en la tabla, así que este caso es casi siempre el reintento.
      #
      # "Casi siempre" no es "siempre": podría venir de otro sistema facturando
      # para el mismo obligado. Por eso el estado del duplicado se guarda en la
      # descripción en vez de tragárselo, y si figura Anulada hay un problema real.
      def estado_de(linea)
        return 'anotado' if linea.duplicado?
        return 'anotado' if linea.correcto?
        return 'aceptado_con_errores' if linea.aceptado_con_errores?

        'rechazado'
      end

      def descripcion_de(linea)
        return linea.descripcion_error unless linea.duplicado?

        "Duplicado: el registro ya constaba en la AEAT con estado " \
          "#{linea.duplicado.estado} (petición #{linea.duplicado.id_peticion}). " \
          "#{linea.descripcion_error}".strip
      end
    end
  end
end
