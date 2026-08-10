# frozen_string_literal: true

module VerifactuRails
  module Libro
    # Contraste entre lo que dice el libro registro y lo que la AEAT tiene
    # realmente anotado.
    #
    # SOLO LEE. No corrige nada, ni siquiera lo que parece obvio, y es una
    # decisión, no una versión reducida: lo que esto detecta es divergencia entre
    # el sistema de registro y la AEAT, y un job que reescribiera el estado local
    # para "cuadrar" taparía justo lo que se le ha pedido revelar. Además no hace
    # falta: Remesa ya reintenta sola lo que quedó en 'enviando', porque un
    # duplicado cuenta como éxito.
    #
    # QUÉ PUEDE Y QUÉ NO PUEDE COMPROBAR. La consulta devuelve una FOTO POR
    # FACTURA, no el histórico de registros (comprobado contra preproducción: 6
    # registros sobre 4 facturas devolvieron 4 filas). Una subsanación sustituye
    # al alta original y la anulación sustituye a lo anulado, así que los
    # eslabones intermedios ya no se devuelven. Consecuencias directas:
    #
    #   - Se reconcilia el ESTADO ACTUAL de cada factura. Es lo que esto hace.
    #   - NO se puede auditar el encadenamiento contra la AEAT. Los registros
    #     sustituidos faltan, y los que encadenaban tras ellos parecen huérfanos
    #     aunque la cadena esté intacta. Detectar una bifurcación sigue siendo
    #     cosa del índice único local, no de aquí.
    #
    # Por eso se compara contra el registro VIGENTE de cada factura -el último
    # anotado con ese IDFactura-, que es el que la AEAT debería estar
    # devolviendo.
    class Reconciliacion
      # La AEAT avisa de que preproducción es para pruebas puntuales, no para
      # carga. Un tope explícito evita que un fallo de paginación se convierta en
      # una tromba de peticiones; que se ha alcanzado se DICE (Informe#truncado?)
      # en vez de devolver medio informe con cara de completo.
      MAXIMO_PAGINAS = 100

      # Los importes no se comparan: la AEAT los devuelve sin ceros a la derecha
      # ('121' por '121.00'), así que un cotejo textual daría falsos positivos a
      # mansalva. No se pierde nada, porque los importes entran en la huella y la
      # huella sí se compara.
      Divergencia = Struct.new(:tipo, :id_emisor, :num_serie, :fecha_expedicion,
                               :local, :remoto, :detalle, keyword_init: true) do
        def to_s = "#{num_serie}: #{tipo} — #{detalle}"
      end

      Informe = Struct.new(:ejercicio, :periodo, :facturas_locales, :filas_aeat,
                           :ajenas, :divergencias, :truncado, keyword_init: true) do
        def cuadra? = divergencias.empty?
        def truncado? = truncado == true

        def to_s
          base = "#{ejercicio}-#{periodo}: #{facturas_locales} facturas locales, " \
                 "#{filas_aeat} filas de la AEAT, #{divergencias.size} divergencias"
          base += ", #{ajenas} de otra instalación" if ajenas.positive?
          base += ' (INFORME TRUNCADO: se alcanzó el tope de páginas)' if truncado?
          base
        end
      end

      def initialize(cadena, transporte:)
        @cadena = cadena
        @transporte = transporte
      end

      # @param periodo [String, Integer] mes de imputación (8 y '08' valen igual).
      # @return [Informe]
      def revisar(ejercicio:, periodo:)
        periodo = format('%<mes>02d', mes: periodo.to_i)
        remotas, truncado = descargar(ejercicio: ejercicio, periodo: periodo)
        nuestras, ajenas = remotas.partition { |fila| de_esta_instalacion?(fila) }
        pendientes = nuestras.index_by { |fila| clave(fila) }

        divergencias = vigentes(ejercicio: ejercicio, periodo: periodo).flat_map do |id, local|
          comparar(local, pendientes.delete(id))
        end
        # Lo que sobra está en la AEAT y no en el libro. Es el caso grave: o
        # factura otro sistema para este obligado, o se reutilizó un número de
        # instalación que ya tenía historia.
        divergencias += pendientes.each_value.map { |fila| solo_en_aeat(fila) }

        Informe.new(ejercicio: ejercicio.to_s, periodo: periodo,
                    facturas_locales: vigentes(ejercicio: ejercicio, periodo: periodo).size,
                    filas_aeat: nuestras.size, ajenas: ajenas.size,
                    divergencias: divergencias, truncado: truncado)
      end

      private

      attr_reader :cadena, :transporte

      # El registro VIGENTE de cada factura: el último anotado con ese IDFactura.
      # El índice (id_emisor, num_serie, fecha_expedicion) NO es único a
      # propósito -una subsanación reutiliza el mismo IDFactura-, así que aquí
      # puede haber varias filas por factura y solo la última cuenta.
      #
      # Se filtra por mes de expedición asumiendo que la AEAT imputa por ella. Es
      # la lectura natural y la que usó la campaña contra preproducción, pero es
      # una suposición: si algún día no cuadra, mira aquí primero.
      def vigentes(ejercicio:, periodo:)
        @vigentes ||= {}
        @vigentes[[ejercicio.to_s, periodo]] ||=
          cadena.registros
                .where('fecha_expedicion LIKE ?', "%-#{periodo}-#{ejercicio}")
                .order(:id)
                .each_with_object({}) { |fila, h| h[clave(fila)] = fila }
      end

      def clave(fila)
        [fila.id_emisor, fila.num_serie, fila.fecha_expedicion]
      end

      # La fila es de esta cadena si la AEAT la atribuye a nuestra instalación.
      #
      # Se filtra AQUÍ, en cliente, además de mandar el SistemaInformatico en el
      # filtro de la consulta. Todo apunta a que el servidor aplica ese cotejo (6
      # facturas del mismo NIF y periodo en dos instalaciones, la consulta
      # devolvió solo las 2 de la consultada), pero no está cerrado: falta
      # verificar que las otras 4 siguieran almacenadas. Ver doc/FUENTES.md.
      #
      # Sea o no redundante, esto se queda: es barato, y hace que el informe siga
      # siendo correcto tanto si la premisa falla como si algún día cambia el
      # cotejo del servidor, en vez de llenarse de :solo_en_aeat por facturas de
      # otras tiendas.
      #
      # Una fila sin NumeroInstalacion se da por nuestra: preferimos revisarla de
      # más a dejar pasar una factura ajena sin mirar.
      def de_esta_instalacion?(fila)
        fila.numero_instalacion.nil? ||
          fila.numero_instalacion == cadena.numero_instalacion
      end

      def comparar(local, remoto)
        return [] if remoto.nil? && sin_constancia_esperada?(local)
        return [divergencia(:no_consta, local, nil, detalle_no_consta(local))] if remoto.nil?
        return [divergencia(:consta_sin_enviar, local, remoto, detalle_sin_enviar(local, remoto))] if sin_enviar?(local)

        # Si la huella no coincide, lo que la AEAT guarda NO es este registro, y
        # comparar además el estado solo añadiría ruido sobre otro documento.
        if remoto.huella != local.huella
          return [divergencia(:huella_distinta, local, remoto,
                              "la AEAT guarda la huella #{remoto.huella} y el libro " \
                              "#{local.huella} para esta factura")]
        end

        esperado = estado_esperado(local)
        return [] if remoto.estado == esperado

        [divergencia(:estado_distinto, local, remoto,
                     "la AEAT dice #{remoto.estado} y el libro esperaba #{esperado}")]
      end

      # Que no conste no siempre es divergencia: lo que aún no se ha enviado no
      # tiene por qué estar, y un registro RECHAZADO no se almacena en la AEAT,
      # así que su ausencia es justo lo correcto.
      def sin_constancia_esperada?(local)
        sin_enviar?(local) || local.estado == 'rechazado'
      end

      def sin_enviar?(local) = %w[pendiente enviando].include?(local.estado)

      def estado_esperado(local)
        return 'Anulado' if local.tipo == 'anulacion'
        return 'AceptadoConErrores' if local.estado == 'aceptado_con_errores'

        'Correcto'
      end

      def detalle_no_consta(local)
        "el libro la da por #{local.estado} pero la AEAT no la devuelve; " \
          'no consta remitida'
      end

      def detalle_sin_enviar(local, remoto)
        coincide = remoto.huella == local.huella ? 'y la huella coincide' : 'pero con OTRA huella'
        "el libro la tiene en '#{local.estado}' y la AEAT ya la tiene anotada " \
          "#{coincide}: el envío llegó y no nos enteramos"
      end

      def solo_en_aeat(fila)
        Divergencia.new(
          tipo: :solo_en_aeat, id_emisor: fila.id_emisor, num_serie: fila.num_serie,
          fecha_expedicion: fila.fecha_expedicion, local: nil, remoto: fila,
          detalle: 'la AEAT tiene esta factura en esta instalación y el libro no ' \
                   'la conoce: o factura otro sistema para este obligado, o se ' \
                   'reutilizó un número de instalación con historia'
        )
      end

      def divergencia(tipo, local, remoto, detalle)
        Divergencia.new(tipo: tipo, id_emisor: local.id_emisor,
                        num_serie: local.num_serie,
                        fecha_expedicion: local.fecha_expedicion,
                        local: local, remoto: remoto, detalle: detalle)
      end

      def descargar(ejercicio:, periodo:)
        filas = []
        clave = nil

        MAXIMO_PAGINAS.times do
          respuesta = pedir(ejercicio: ejercicio, periodo: periodo, clave: clave)
          filas.concat(respuesta.registros)

          return [filas, false] unless respuesta.hay_mas_paginas?

          clave = respuesta.clave_paginacion
          # Paginación "S" sin clave dejaría un bucle infinito pidiendo lo mismo.
          return [filas, false] if clave.nil?
        end

        [filas, true]
      end

      def pedir(ejercicio:, periodo:, clave:)
        consulta = Consulta.new(
          nif_obligado: cadena.nif_obligado, nombre_obligado: cadena.nombre_obligado,
          ejercicio: ejercicio, periodo: periodo,
          sistema_informatico: cadena.sistema_informatico, clave_paginacion: clave
        )
        RespuestaConsulta.new(transporte.enviar(consulta.to_xml).fetch(:cuerpo))
      end
    end
  end
end
