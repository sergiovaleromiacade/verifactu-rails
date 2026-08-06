# frozen_string_literal: true

require 'time'
require 'date'
require_relative 'error'

module VerifactuRails
  # Normalización canónica de los valores que aparecen a la vez en la cadena de la
  # huella y en el XML.
  #
  # REGLA DE ORO, la misma que rige Importe: la AEAT recalcula la huella sobre lo
  # que recibe en el XML. Si un valor se normaliza distinto en cada sitio, rechazo.
  # Por eso fechas y marcas temporales viven aquí y no duplicadas en cada módulo.
  #
  # (El escapado XML es harina de otro costal y no rompe esta regla: la huella se
  # calcula sobre el valor crudo y el XML lo escapa, pero la AEAT desescapa antes
  # de recalcular. Una serie "A&B" va cruda a la huella y como "A&amp;B" al XML.)
  module Formato
    module_function

    # Espacios al inicio y al final: la spec NO es ambigua, dice recortarlos.
    #
    #   "Los valores de los campos deberán tener la misma información contenida
    #    en el campo correspondiente del fichero XML, pero eliminando los
    #    espacios al inicio y al final de cada valor"
    #   (Especificaciones huella v0.1.2, ap. 3)
    #
    # Aquí rechazamos en vez de recortar, que es MÁS ESTRICTO que la norma: un
    # valor con espacios al borde casi siempre es un defecto de los datos de
    # origen, y recortar en silencio lo taparía. Los espacios interiores sí se
    # respetan ("12345678 / G33" es un NumSerieFactura válido y así lo ejemplifica
    # la propia AEAT).
    def texto(valor, campo)
      cadena = valor.to_s
      raise ValidacionError, "#{campo} no puede estar vacío" if cadena.empty?

      if cadena != cadena.strip
        raise ValidacionError,
              "#{campo} contiene espacios al inicio o final: #{cadena.inspect}. " \
              'Normalízalo antes de generar el registro.'
      end
      cadena
    end

    # Tipo sf:fecha del XSD: exactamente dd-mm-yyyy.
    def fecha(valor)
      objeto = valor.is_a?(String) ? Date.strptime(valor, '%d-%m-%Y') : valor
      # Guarda explícita, como en marca_temporal: sin ella, un nil se escapaba
      # del contrato de errores del módulo con un NoMethodError en vez de un
      # ValidacionError, porque el rescue de abajo no captura NoMethodError.
      unless objeto.respond_to?(:strftime)
        raise ValidacionError, "Fecha inválida (se espera Date o 'dd-mm-yyyy'): #{valor.inspect}"
      end

      objeto.strftime('%d-%m-%Y')
    rescue ArgumentError, TypeError
      raise ValidacionError, "Fecha inválida (se espera Date o 'dd-mm-yyyy'): #{valor.inspect}"
    end

    # ISO 8601 con offset explícito. OJO: Ruby serializa UTC como "Z" mientras
    # que la referencia usa "+00:00"; forzamos siempre ±HH:MM para que la huella
    # coincida con la de otras implementaciones y con el XML.
    def marca_temporal(valor)
      tiempo = valor.is_a?(String) ? Time.iso8601(valor) : valor
      raise ValidacionError, 'fecha_hora_gen debe ser Time o String ISO 8601' unless tiempo.respond_to?(:strftime)

      tiempo.strftime('%Y-%m-%dT%H:%M:%S%:z')
    rescue ArgumentError => e
      raise ValidacionError, "fecha_hora_gen inválida: #{valor.inspect} (#{e.message})"
    end

    # Longitud fija de 9 según sf:NIFType. El XSD no valida el dígito de control,
    # y nosotros tampoco: rechazar un NIF válido por una tabla desactualizada
    # sería peor que dejar que la AEAT lo rechace.
    # Se normaliza a MAYÚSCULAS, y esto sí es una excepción deliberada a la regla
    # de "rechazar en vez de arreglar" que rige `texto`.
    #
    # Motivo, comprobado contra preproducción: un NIF con la letra en minúscula
    # ("89890001k") supera la validación de FORMATO de la AEAT (no da 4116) pero
    # falla la búsqueda en el censo, que sí distingue mayúsculas, y devuelve un
    # 4104 "no está identificado" que apunta al sitio equivocado: parece que el
    # NIF no existe cuando lo único que pasa es que va en minúscula.
    #
    # La diferencia con los espacios al borde es que ahí el valor original podía
    # significar algo (un campo de ancho fijo mal recortado, por ejemplo) y
    # recortar lo taparía. Aquí no: la forma canónica de un NIF es en mayúsculas
    # y "c" y "C" denotan la misma letra de control. No se pierde información.
    def nif(valor, campo = 'NIF')
      cadena = texto(valor, campo).upcase
      unless cadena.length == 9
        raise ValidacionError, "#{campo} debe tener 9 caracteres: #{cadena.inspect}"
      end

      cadena
    end

    # NumSerieFactura solo admite ASCII imprimible (32-126) y prohíbe además
    # cinco caracteres concretos (Validaciones v1.2.2, ap. 3.1.3.1).
    #
    # Ojo a la asimetría: "&" SÍ está permitido, y es justo el que obliga a
    # escapar en el XML mientras la huella lo usa crudo. Los que romperían el
    # XML de verdad (< > ") están prohibidos de entrada por la AEAT.
    PROHIBIDOS_SERIE = ['"', "'", '<', '>', '='].freeze

    def num_serie(valor, campo = 'NumSerieFactura')
      cadena = limitar(valor, campo, 60)

      malos = cadena.chars.reject { |c| c.ord.between?(32, 126) }.uniq
      unless malos.empty?
        raise ValidacionError,
              "#{campo} solo admite ASCII imprimible (32-126); sobran: " \
              "#{malos.map(&:inspect).join(', ')}"
      end

      encontrados = PROHIBIDOS_SERIE.select { |c| cadena.include?(c) }
      unless encontrados.empty?
        raise ValidacionError,
              "#{campo} no admite los caracteres #{encontrados.map(&:inspect).join(', ')}: " \
              "#{cadena.inspect}"
      end

      cadena
    end

    def limitar(valor, campo, maximo)
      cadena = texto(valor, campo)
      if cadena.length > maximo
        raise ValidacionError,
              "#{campo} excede #{maximo} caracteres (#{cadena.length}): #{cadena.inspect}"
      end

      cadena
    end

    # Campos sf:SiNoType. Acepta el booleano de Ruby y también la letra de la
    # AEAT, porque quien lee la documentación escribe 'S'/'N' de forma natural.
    #
    # Lo que NO puede pasar es tratarlo como valor de verdad a secas: 'N' es
    # truthy en Ruby, así que `multi_ot ? 'S' : 'N'` emitía 'S' cuando el usuario
    # había pedido 'N', invirtiendo la declaración en silencio.
    def si_no(valor, campo)
      case valor
      when nil       then nil
      when true, 'S' then 'S'
      when false, 'N' then 'N'
      else
        raise ValidacionError,
              "#{campo} debe ser true/false o 'S'/'N' (recibido: #{valor.inspect})"
      end
    end

    # Colección homogénea de objetos de valor.
    #
    # No basta con Array(): Array(hash) devuelve los PARES del hash, así que un
    # `destinatarios: {nombre_razon: 'X', nif: '...'}` se convertía en dos
    # "destinatarios" que pasaban las validaciones de conteo y solo reventaban
    # al serializar, con un NoMethodError sobre un Array. Aquí el criterio es el
    # mismo que en el resto de la gema: si el objeto se construye, es emitible.
    def coleccion(valor, campo, clase, maximo: nil)
      lista = valor.nil? ? [] : Array(valor)

      if valor.is_a?(Hash) || (valor && !valor.is_a?(Array) && !valor.is_a?(clase))
        raise ValidacionError,
              "#{campo} debe ser un #{clase} o un array de #{clase} " \
              "(recibido: #{valor.class})"
      end
      lista = [valor] if valor.is_a?(clase)

      intrusos = lista.reject { |e| e.is_a?(clase) }.map(&:class).uniq
      unless intrusos.empty?
        raise ValidacionError,
              "#{campo} solo admite #{clase} (encontrados: #{intrusos.join(', ')})"
      end
      if maximo && lista.size > maximo
        raise ValidacionError,
              "#{campo} admite como mucho #{maximo} elementos (recibidos #{lista.size})"
      end

      lista
    end

    # Colaborador obligatorio de una clase concreta.
    def objeto(valor, campo, clase)
      return valor if valor.is_a?(clase)

      raise ValidacionError, "#{campo} debe ser un #{clase} (recibido: #{valor.class})"
    end

    def enumerado(valor, campo, admitidos)
      cadena = texto(valor, campo)
      unless admitidos.include?(cadena)
        raise ValidacionError,
              "#{campo} inválido: #{cadena.inspect}. Admitidos: #{admitidos.join(', ')}"
      end

      cadena
    end
  end
end
