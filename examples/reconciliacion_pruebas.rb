# frozen_string_literal: true

# Reconciliación del libro registro contra lo que la AEAT tiene anotado.
#
#   VF_P12=/ruta/cert.p12 VF_PASS=xxxx VF_INSTALACION=CAMP-2026... \
#     ruby -Ilib examples/reconciliacion_pruebas.rb
#
# Contrasta, factura a factura, el libro local con la consulta del servicio real.
# Es de SOLO LECTURA por partida doble: la consulta no modifica nada en la AEAT y
# `Reconciliacion` no toca la base de datos. Se puede correr sin miedo.
#
# Con este guion se comprobaron el 10-08-2026 las dos cosas que los tests no
# pueden decidir, y que hasta entonces eran suposiciones del código (ver
# doc/FUENTES.md): que el cotejo del SistemaInformatico SÍ lo aplica el servidor,
# y que la AEAT imputa el periodo por FECHA DE EXPEDICIÓN, que es lo que asume
# `Reconciliacion#vigentes` al elegir qué facturas locales revisar.
#
# Necesita base de datos: VF_DATABASE_URL o DATABASE_URL, y si no PostgreSQL
# local en verifactu_rails_test.
#
# AVISO: preproducción es para pruebas PUNTUALES. Esto es una consulta por
# página; no lo pongas en un bucle.

require 'active_record'
require_relative '../lib/verifactu_rails/libro'

include VerifactuRails

def env!(nombre)
  ENV[nombre] || abort("Falta la variable #{nombre}. Ver la cabecera de este fichero.")
end

url = ENV['VF_DATABASE_URL'] || ENV['DATABASE_URL'] ||
      'postgresql://localhost/verifactu_rails_test'
ActiveRecord::Base.establish_connection(url)
begin
  ActiveRecord::Base.connection.execute('select 1')
rescue StandardError => e
  abort "No se pudo conectar a #{url}: #{e.message.lines.first}"
end
puts "Base de datos: #{url}"

instalacion = env!('VF_INSTALACION')
cadena = Libro::Cadena.find_by(numero_instalacion: instalacion) ||
         abort("No hay ninguna cadena con numero_instalacion #{instalacion.inspect}. " \
               "Las que hay: #{Libro::Cadena.pluck(:numero_instalacion).inspect}")

certificado = Certificado.desde_pkcs12(File.binread(env!('VF_P12')), env!('VF_PASS'))
puts "Certificado: #{certificado.resumen}"

# El SIF que se manda en el filtro de la consulta tiene que ser el MISMO con el
# que se anotaron los registros: si el servidor aplica el cotejo y no coincide,
# la respuesta viene SinDatos y todo parece "no consta" sin serlo.
#
# Por eso no se pone a mano: se lee del payload del último registro anotado, que
# es el XML tal cual se remitió. Adivinarlo es un error que además se disfraza de
# divergencia, que es la peor forma de equivocarse aquí.
def sif_anotado(cadena)
  registro = cadena.registros.order(:id).last
  abort "La cadena #{cadena.numero_instalacion} no tiene registros." if registro.nil?

  nodo = Nokogiri::XML(registro.payload)
              .at_xpath('//*[local-name()="SistemaInformatico"]')
  abort 'El payload no trae SistemaInformatico.' if nodo.nil?

  %w[NombreRazon NIF NombreSistemaInformatico IdSistemaInformatico Version]
    .to_h { |campo| [campo, nodo.at_xpath("*[local-name()='#{campo}']")&.text] }
end

sif = sif_anotado(cadena)
puts "SIF con el que se anotó: #{sif['NombreSistemaInformatico']} " \
     "#{sif['IdSistemaInformatico']} v#{sif['Version']} (#{sif['NombreRazon']})"

Libro.configure do |c|
  c.productor_nombre = sif['NombreRazon']
  c.productor_nif    = sif['NIF']
  c.nombre_sistema   = sif['NombreSistemaInformatico']
  c.id_sistema       = sif['IdSistemaInformatico']
  c.version          = sif['Version']
  c.entorno          = (ENV['VF_ENTORNO'] || 'pruebas').to_sym
end

ejercicio = ENV['VF_EJERCICIO'] || Time.now.year.to_s
periodo   = ENV['VF_PERIODO'] || format('%<mes>02d', mes: Time.now.month)

transporte = Transporte.new(certificado: certificado,
                            entorno: Libro.configuracion.entorno,
                            sello: ENV['VF_SELLO'])

puts "\nReconciliando #{instalacion} contra #{transporte.url}"
puts "Periodo #{ejercicio}-#{periodo}\n\n"

informe = Libro::Reconciliacion.new(cadena, transporte: transporte)
                               .revisar(ejercicio: ejercicio, periodo: periodo)

puts informe

if informe.cuadra?
  puts "\nCuadra: el libro y la AEAT dicen lo mismo de cada factura."
else
  puts "\n=== #{informe.divergencias.size} divergencias ==="
  informe.divergencias.group_by(&:tipo).each do |tipo, lista|
    puts "\n#{tipo} (#{lista.size}):"
    lista.each { |d| puts "  #{d.num_serie}: #{d.detalle}" }
  end
end

puts "\nRecuerda: esto compara el ESTADO ACTUAL de cada factura. El " \
     'encadenamiento NO se puede auditar desde aquí, porque los eslabones ' \
     'sustituidos por una subsanación ya no se devuelven.'
