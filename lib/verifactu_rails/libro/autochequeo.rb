# frozen_string_literal: true

module VerifactuRails
  module Libro
    # Las comprobaciones que el art. 7.i) de la Orden HAC/1177/2024 obliga a hacer
    # ANTES de generar cada registro:
    #
    #   1.º El último registro de facturación generado está correctamente
    #       encadenado.
    #   2.º La fecha y hora de generación del último registro no es superior en
    #       más de un minuto a la fecha y hora actuales.
    #
    # DEVUELVE una lista de anomalías; no levanta excepciones. Es deliberado: las
    # FAQs dicen que "será preciso generar el siguiente RF, ya que la facturación
    # por este motivo NUNCA debe interrumpirse". Bloquear la caja por un problema
    # de trazabilidad es peor remedio que la enfermedad.
    class Autochequeo
      # El minuto del art. 7.i).2.º.
      MARGEN_RELOJ = 60

      def initialize(anterior)
        @anterior = anterior
      end

      # @param ahora [Time] la hora con la que se va a fechar el nuevo registro
      # @return [Array<Symbol>] vacío si todo cuadra
      def anomalias(ahora:)
        return [] if anterior.nil? # "salvo cuando se trate del primer registro"

        fallos = []
        fallos << :encadenamiento_roto unless eslabon_cuadra?
        fallos << :huella_alterada unless anterior.huella_cuadra?
        fallos << :reloj_hacia_atras if reloj_atrasado?(ahora)
        fallos
      end

      private

      attr_reader :anterior

      # Lo que pide literalmente la Orden: que la huella que el RF n-1 guarda de
      # su predecesor se corresponda con la huella del RF n-2. Un eslabón atrás,
      # no la cadena entera.
      def eslabon_cuadra?
        return anterior.cadena.registros.where(huella_anterior: '').count == 1 if anterior.primero?

        anterior.cadena.registros.exists?(huella: anterior.huella_anterior)
      end

      # Esto va MÁS ALLÁ de lo que exige la Orden: recalcula la huella del
      # anterior desde sus columnas y la compara con la almacenada. Es un
      # SHA-256, y es lo único que detecta que alguien haya editado la fila en la
      # base de datos. Ser más estricto aquí no tiene el riesgo habitual porque
      # no bloquea nada: solo anota.
      #
      # (La comprobación vive en Registro#huella_cuadra?)

      # OJO al sentido, que es el que confunde: que pasen horas entre registros es
      # lo normal y no es anomalía. Lo que no se admite es fechar el nuevo
      # registro MÁS DE UN MINUTO ANTES que el anterior, o sea que el reloj haya
      # ido hacia atrás.
      def reloj_atrasado?(ahora)
        ahora < anterior.momento - MARGEN_RELOJ
      end
    end
  end
end
