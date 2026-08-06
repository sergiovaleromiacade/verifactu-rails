require 'tmpdir'
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'support/pki'
require_relative '../lib/verifactu_rails/certificado'
require_relative '../lib/verifactu_rails/transporte'

class CertificadoTest < Minitest::Test
  def setup
    @ca_cert, @ca_key = PKI.ca
  end

  def test_carga_desde_pkcs12
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL/O=ACME SL/serialNumber=B12345678')
    p12 = PKI.pkcs12(cert, key, 'secreto')

    certificado = VerifactuRails::Certificado.desde_pkcs12(p12, 'secreto')
    assert_equal 'ACME SL', certificado.sujeto['CN']
    assert_equal 'B12345678', certificado.sujeto['serialNumber']
  end

  def test_password_incorrecta_da_error_legible
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL')
    p12 = PKI.pkcs12(cert, key, 'secreto')

    error = assert_raises(VerifactuRails::CertificadoError) do
      VerifactuRails::Certificado.desde_pkcs12(p12, 'incorrecta')
    end
    assert_match(/contraseña incorrecta o fichero corrupto/, error.message)
  end

  def test_rechaza_certificado_caducado
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL',
                                              not_before: Time.now - (400 * 86_400),
                                              not_after: Time.now - 86_400)
    p12 = PKI.pkcs12(cert, key, 'x')
    error = assert_raises(VerifactuRails::CertificadoError) { VerifactuRails::Certificado.desde_pkcs12(p12, 'x') }
    assert_match(/caducado/, error.message)
  end

  def test_avisa_de_caducidad_proxima
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL',
                                              not_after: Time.now + (10 * 86_400))
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    assert certificado.caduca_pronto?
    assert_in_delta 10, certificado.dias_para_caducar, 1
  end

  def test_no_avisa_si_queda_mucho
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    refute certificado.caduca_pronto?
  end

  def test_detecta_certificado_de_sello
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=SELLO ELECTRONICO ACME SL/O=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    assert certificado.sello?
  end

  def test_representante_no_se_marca_como_sello
    cert, key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=JUAN PEREZ - 12345678Z/O=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
    refute certificado.sello?
  end

  def test_datos_vacios
    assert_raises(VerifactuRails::CertificadoError) { VerifactuRails::Certificado.desde_pkcs12('', 'x') }
  end
end

class EndpointTest < Minitest::Test
  def setup
    ca_cert, ca_key = PKI.ca
    cert, key = PKI.emitir(ca_cert, ca_key, subject: '/CN=ACME SL')
    @cert = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(cert, key, 'x'), 'x')
  end

  def test_pruebas_normal
    t = VerifactuRails::Transporte.new(certificado: @cert, entorno: :pruebas, sello: false)
    assert_equal 'prewww1.aeat.es', URI.parse(t.url).host
  end

  def test_pruebas_sello_usa_host_distinto
    t = VerifactuRails::Transporte.new(certificado: @cert, entorno: :pruebas, sello: true)
    assert_equal 'prewww10.aeat.es', URI.parse(t.url).host
  end

  def test_produccion_normal_y_sello
    normal = VerifactuRails::Transporte.new(certificado: @cert, entorno: :produccion, sello: false)
    sello  = VerifactuRails::Transporte.new(certificado: @cert, entorno: :produccion, sello: true)
    assert_equal 'www1.agenciatributaria.gob.es', URI.parse(normal.url).host
    assert_equal 'www10.agenciatributaria.gob.es', URI.parse(sello.url).host
    refute_equal normal.url, sello.url
  end

  def test_sello_se_deduce_del_certificado
    ca_cert, ca_key = PKI.ca
    c, k = PKI.emitir(ca_cert, ca_key, subject: '/CN=SELLO ELECTRONICO ACME/O=ACME SL')
    certificado = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(c, k, 'x'), 'x')
    assert VerifactuRails::Transporte.new(certificado: certificado, entorno: :pruebas).sello?
  end

  def test_entorno_invalido
    assert_raises(ArgumentError) { VerifactuRails::Transporte.new(certificado: @cert, entorno: :staging) }
  end

  def test_por_defecto_apunta_a_pruebas
    assert_includes VerifactuRails::Transporte.new(certificado: @cert).url, 'prewww'
  end
end

# La prueba que importa: handshake mTLS completo contra un servidor real.
class TransporteMTLSTest < Minitest::Test
  def setup
    @ca_cert, @ca_key = PKI.ca
    srv_cert, srv_key = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=localhost',
                                                      san: 'DNS:localhost,IP:127.0.0.1')
    @ca_file = File.join(Dir.tmpdir, "ca-#{Process.pid}.pem")
    File.write(@ca_file, @ca_cert.to_pem)

    @servidor = ServidorMTLS.new(ca_cert: @ca_cert, server_cert: srv_cert, server_key: srv_key,
                                 respuesta: '<RespuestaSuministro>OK</RespuestaSuministro>').arrancar
  end

  def teardown
    @servidor.parar
    File.delete(@ca_file) if File.exist?(@ca_file)
  end

  def test_handshake_mtls_y_entrega_del_xml
    transporte = transporte_local(cliente_valido)
    resultado = transporte.enviar('<RegFactuSistemaFacturacion>...</RegFactuSistemaFacturacion>')

    assert_equal 200, resultado[:codigo]
    assert_includes resultado[:cuerpo], 'RespuestaSuministro'

    peticion = @servidor.peticiones.first
    refute_nil peticion, 'el servidor no recibió la petición'
    # El servidor vio el certificado de cliente: mTLS efectivo, no solo TLS.
    assert_equal 'ACME SL', peticion[:cn_cliente]
    assert_equal 'text/xml; charset=utf-8', peticion[:cabeceras]['content-type']
    assert_includes peticion[:cuerpo], 'RegFactuSistemaFacturacion'
    assert_includes peticion[:cuerpo], 'soapenv:Envelope'
  end

  def test_certificado_de_otra_ca_es_rechazado
    otra_ca_cert, otra_ca_key = PKI.ca(cn: 'CA Impostora')
    c, k = PKI.emitir(otra_ca_cert, otra_ca_key, subject: '/CN=IMPOSTOR SL')
    intruso = VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(c, k, 'x'), 'x')

    assert_raises(VerifactuRails::TransporteError) do
      transporte_local(intruso).enviar('<x/>')
    end
    assert_empty @servidor.peticiones
  end

  def test_ca_desconocida_da_mensaje_util
    transporte = VerifactuRails::Transporte.new(
      certificado: cliente_valido, entorno: :pruebas,
      url: "https://localhost:#{@servidor.puerto}/" # sin ca_file
    )
    error = assert_raises(VerifactuRails::TransporteError) { transporte.enviar('<x/>') }
    assert_match(/No uses VERIFY_NONE/, error.message)
  end

  def test_el_sobre_soap_es_valido
    transporte = transporte_local(cliente_valido)
    sobre = transporte.envolver('<Cabecera/>')
    assert_includes sobre, 'http://schemas.xmlsoap.org/soap/envelope/'
    assert_includes sobre, '<soapenv:Body><Cabecera/></soapenv:Body>'
  end

  private

  def cliente_valido
    @cliente_valido ||= begin
      c, k = PKI.emitir(@ca_cert, @ca_key, subject: '/CN=ACME SL/O=ACME SL')
      VerifactuRails::Certificado.desde_pkcs12(PKI.pkcs12(c, k, 'x'), 'x')
    end
  end

  def transporte_local(certificado)
    VerifactuRails::Transporte.new(certificado: certificado, entorno: :pruebas,
                              url: "https://localhost:#{@servidor.puerto}/",
                              ca_file: @ca_file, timeout: 5)
  end
end
