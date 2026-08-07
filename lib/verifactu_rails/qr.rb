# frozen_string_literal: true

require 'uri'
require_relative 'error'

module VerifactuRails
  # URL de cotejo del código QR que debe llevar la factura.
  #
  # La AEAT NO devuelve esta URL en ninguna respuesta: la construye el propio SIF
  # con datos que ya tiene. Por eso el QR no depende del envío y se puede generar
  # en el momento de crear el registro, aunque la AEAT esté caída.
  #
  # Ojo al matiz: que el QR sea válido no significa que la factura conste. Si el
  # envío nunca llega a completarse, quien escanee obtendrá un "no consta".
  module QR
    # El host NO es el de los envíos: el cotejo va por prewww2 / www2, mientras
    # que el SOAP va por prewww1/prewww10 y www1/www10.
    BASES = {
      pruebas: 'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR',
      produccion: 'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR'
    }.freeze

    module_function

    # @param registro [RegistroAlta]
    def url(registro, entorno: :pruebas)
      componer(nif: registro.id_emisor, num_serie: registro.num_serie,
               fecha: registro.fecha_expedicion, importe: registro.importe_total,
               entorno: entorno)
    end

    # Los cuatro parámetros sueltos. Se expone aparte del registro para poder
    # reproducir el ejemplo oficial del PDF, cuya fecha (01-01-2024) es anterior
    # a la entrada en vigor y por tanto no se puede montar como RegistroAlta.
    def componer(nif:, num_serie:, fecha:, importe:, entorno: :pruebas)
      base = BASES.fetch(entorno) do
        raise ValidacionError, "Entorno desconocido para el QR: #{entorno.inspect}"
      end
      pares = { 'nif' => nif, 'numserie' => num_serie,
                'fecha' => fecha, 'importe' => importe }

      "#{base}?#{pares.map { |k, v| "#{k}=#{codificar(v)}" }.join('&')}"
    end

    # El PDF de especificaciones dedica un apartado a esto y pone como
    # contraejemplo un numserie=12345678&G33 sin codificar, que parte la URL. Y el
    # caso es alcanzable: Formato.num_serie prohíbe " ' < > = pero SÍ admite &, %,
    # + y espacios.
    #
    # El espacio se codifica como %20 y no como "+": ambos son válidos en un query
    # string, pero "+" solo se interpreta como espacio bajo
    # application/x-www-form-urlencoded, y aquí no hay forma de saber cómo lo
    # decodifica la AEAT. %20 significa espacio en cualquier lectura.
    def codificar(valor) = URI.encode_www_form_component(valor.to_s).gsub('+', '%20')
  end
end
