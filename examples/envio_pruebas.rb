# frozen_string_literal: true

# Envío de humo contra el entorno de PRUEBAS de la AEAT (prewww1/prewww10).
#
#   VF_P12=/ruta/cert.p12 VF_PASS=xxxx VF_NIF=B12345678 VF_NOMBRE='Tu Empresa SL' \
#     ruby -Ilib examples/envio_pruebas.rb
#
# El certificado se lee de una ruta que pasas por entorno: no lo copies dentro
# del repositorio (.gitignore bloquea *.p12, pero mejor que ni llegue).
#
# AVISO: preproducción es para pruebas PUNTUALES. La AEAT advierte que un uso
# masivo puede acabar en bloqueo de acceso, así que este guion manda UN registro.

require 'verifactu-rails'
include VerifactuRails

def env!(nombre)
  ENV[nombre] || abort("Falta la variable #{nombre}. Ver la cabecera de este fichero.")
end

nif      = env!('VF_NIF')
nombre   = env!('VF_NOMBRE')
serie    = ENV['VF_SERIE'] || "PRUEBA/#{Time.now.strftime('%Y%m%d%H%M%S')}"
entorno  = (ENV['VF_ENTORNO'] || 'pruebas').to_sym

certificado = Certificado.desde_pkcs12(File.binread(env!('VF_P12')), env!('VF_PASS'))
puts "Certificado: #{certificado.resumen}"
puts "  caduca en #{certificado.dias_para_caducar} días" if certificado.caduca_pronto?

# Estos valores describen TU sistema de facturación, no esta gema.
sistema = SistemaInformatico.new(
  nombre_razon: ENV['VF_PRODUCTOR'] || nombre,
  nif: ENV['VF_PRODUCTOR_NIF'] || nif,
  nombre_sistema: ENV['VF_SISTEMA'] || 'PruebaVerifactuRails',
  id_sistema: ENV['VF_ID_SISTEMA'] || '01',
  version: VerifactuRails::VERSION,
  numero_instalacion: ENV['VF_INSTALACION'] || 'PRUEBA-1'
)

registro = RegistroAlta.new(
  id_emisor: nif, num_serie: serie, fecha_expedicion: Date.today,
  nombre_razon_emisor: nombre, tipo_factura: 'F1',
  descripcion_operacion: 'Prueba de integracion VERI*FACTU',
  desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                         tipo_impositivo: BigDecimal('21'),
                         cuota_repercutida: BigDecimal('21.00'))],
  cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
  sistema_informatico: sistema, fecha_hora_gen: Time.now,
  destinatarios: [Destinatario.new(nombre_razon: 'Cliente de Prueba SL',
                                   nif: ENV['VF_CLIENTE_NIF'] || nif)]
)

# nil = primer registro de la cadena. En un sistema real, el anterior sale de la
# base de datos bajo un lock por NIF+serie.
xml = Envio.new(nif_obligado: nif, nombre_obligado: nombre,
                entradas: [[registro, nil]]).to_xml

puts "\nHuella del registro: #{registro.huella(anterior: nil)}"
puts "Cadena previa al hash (esto es lo que hay que comparar ante un rechazo):"
puts "  #{Huella.cadena_alta(id_emisor: registro.id_emisor, num_serie: registro.num_serie,
                             fecha_expedicion: registro.fecha_expedicion,
                             tipo_factura: registro.tipo_factura,
                             cuota_total: registro.cuota_total,
                             importe_total: registro.importe_total,
                             fecha_hora_gen: registro.fecha_hora_gen)}"

transporte = Transporte.new(certificado: certificado, entorno: entorno,
                            sello: ENV['VF_SELLO'])
puts "\nEnviando a #{transporte.url}"
puts "  (endpoint de #{transporte.sello? ? 'SELLO' : 'certificado normal'})"

resultado = transporte.enviar(xml)
puts "HTTP #{resultado[:codigo]}"

begin
  respuesta = Respuesta.new(resultado[:cuerpo])
  puts "\n#{respuesta}"
  puts "CSV: #{respuesta.csv}"
  puts "Esperar #{respuesta.tiempo_espera}s hasta el siguiente envío"
  respuesta.lineas.each { |l| puts "  #{l}" }

  unless respuesta.a_subsanar.empty?
    puts "\nOJO: quedaron anotados pero OBLIGAN A SUBSANAR (no los reenvíes tal cual;"
    puts 'manda un alta con subsanacion: "S"):'
    respuesta.a_subsanar.each { |l| puts "  #{l}" }
  end
rescue VerifactuRails::RespuestaError => e
  puts "\nNo se pudo interpretar la respuesta: #{e.message}"
  puts resultado[:cuerpo].to_s[0, 2000]
end
