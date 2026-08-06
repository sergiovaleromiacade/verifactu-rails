# frozen_string_literal: true

# Punto de entrada de la gema. El nombre del fichero lleva guion (verifactu-rails)
# para coincidir con el nombre de la gema; los internos van en verifactu_rails/.
require_relative 'verifactu_rails/version'
require_relative 'verifactu_rails/error'
require_relative 'verifactu_rails/formato'
require_relative 'verifactu_rails/importe'
require_relative 'verifactu_rails/huella'
require_relative 'verifactu_rails/desglose'
require_relative 'verifactu_rails/sistema_informatico'
require_relative 'verifactu_rails/registro'
require_relative 'verifactu_rails/envio'
require_relative 'verifactu_rails/certificado'
require_relative 'verifactu_rails/transporte'

# Integración con VERI*FACTU (AEAT) para aplicaciones Ruby y Rails.
#
# ALCANCE: únicamente modalidad VERI*FACTU (remisión continua a la AEAT). No se
# implementa el modo NO VERI*FACTU, que exigiría firma XAdES de cada registro y
# registro de eventos.
module VerifactuRails
end
