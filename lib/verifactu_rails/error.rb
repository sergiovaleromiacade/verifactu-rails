# frozen_string_literal: true

module VerifactuRails
  # Marcador común de todo error propio de la gema.
  #
  # Es un MÓDULO y no una clase base a propósito. `rescue` casa por `Module#===`,
  # así que incluirlo basta para que funcione `rescue VerifactuRails::Error`, y
  # a la vez deja libre la herencia para que cada error conserve la clase de Ruby
  # que le corresponde semánticamente.
  #
  # En concreto, ValidacionError sigue siendo un ArgumentError, que es lo que
  # cualquier rubyista espera al pasar un argumento inválido. Una jerarquía
  # propia colgando de StandardError habría obligado a elegir entre una cosa y
  # la otra.
  #
  #   begin
  #     registro = VerifactuRails::RegistroAlta.new(...)
  #   rescue VerifactuRails::Error => e   # cualquier cosa que venga de la gema
  #     ...
  #   end
  #
  #   rescue ArgumentError                # sigue atrapando las validaciones
  module Error; end

  # Datos que incumplen el diseño de registro o las validaciones de la AEAT.
  # Se levanta al construir, nunca al serializar: si un objeto existe, su
  # contenido es emitible.
  class ValidacionError < ArgumentError
    include Error
  end
end
