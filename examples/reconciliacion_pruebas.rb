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
# Lo que este guion sirve para averiguar, y que los tests no pueden decidir:
#
#   1. Si el filtro por SistemaInformatico se aplica de verdad en el servidor.
#      La reconciliación no depende de ello -filtra también en cliente por
#      NumeroInstalacion-, pero saberlo cambia cuánto se descarga en cada pasada.
#      Compara el total de filas con las que se atribuyen a esta instalación.
#   2. Si la AEAT imputa al periodo por FECHA DE EXPEDICIÓN, que es lo que asume
#      `Reconciliacion#vigentes` al elegir qué facturas locales revisar.
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

# El SIF que se manda en el filtro de la consulta sale de la configuración, así
# que tiene que ser el MISMO con el que se anotaron los registros. Si no, el
# cotejo del SIF -si el servidor lo aplica- no encontrará nada.
Libro.configure do |c|
  c.productor_nombre = ENV['VF_PRODUCTOR'] || cadena.nombre_obligado
  c.productor_nif    = ENV['VF_PRODUCTOR_NIF'] || cadena.nif_obligado
  c.nombre_sistema   = ENV['VF_SISTEMA'] || 'TuFactura'
  c.id_sistema       = ENV['VF_ID_SISTEMA'] || '01'
  c.version          = ENV['VF_VERSION'] || VerifactuRails::VERSION
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
