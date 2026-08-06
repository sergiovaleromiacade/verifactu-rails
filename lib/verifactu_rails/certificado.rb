# frozen_string_literal: true

require 'openssl'
require_relative 'error'

module VerifactuRails
  class CertificadoError < StandardError
    include Error
  end

  # Envuelve el certificado del obligado tributario usado para la autenticación
  # mutua TLS contra la AEAT.
  #
  # En modalidad VERI*FACTU el certificado NO firma los registros: solo autentica
  # el canal. Aun así es la credencial más sensible del sistema, así que esta clase
  # deliberadamente NO sabe leer ficheros ni variables de entorno: recibe los bytes
  # ya cargados. La política de almacenamiento es de la capa de integración.
  class Certificado
    AVISO_CADUCIDAD_DIAS = 30

    attr_reader :certificado, :clave, :cadena

    def initialize(certificado:, clave:, cadena: nil)
      @certificado = certificado
      @clave = clave
      @cadena = Array(cadena)
      validar!
    end

    # Construye desde los bytes de un .p12/.pfx (lo que el usuario descarga de la
    # FNMT). Evitamos obligarle a partirlo en PEM con openssl a mano.
    def self.desde_pkcs12(datos, password)
      raise CertificadoError, 'Datos PKCS12 vacíos' if datos.nil? || datos.empty?

      p12 = OpenSSL::PKCS12.new(datos, password.to_s)
      new(certificado: p12.certificate, clave: p12.key, cadena: p12.ca_certs)
    rescue OpenSSL::PKCS12::PKCS12Error => e
      raise CertificadoError,
            'No se pudo abrir el PKCS12: contraseña incorrecta o fichero corrupto ' \
            "(#{e.message})"
    end

    def caducado?
      Time.now > certificado.not_after
    end

    def dias_para_caducar
      ((certificado.not_after - Time.now) / 86_400).floor
    end

    # Los .p12 caducan siempre en mal momento. Que el sistema avise solo.
    def caduca_pronto?(umbral = AVISO_CADUCIDAD_DIAS)
      dias_para_caducar <= umbral
    end

    def sujeto
      certificado.subject.to_a.each_with_object({}) { |(k, v, _), h| h[k] = v }
    end

    # Un certificado de sello de entidad se dirige a un endpoint DISTINTO de la
    # AEAT. Heurística sobre el sujeto; el integrador puede forzarlo en config.
    def sello?
      valores = sujeto.values.join(' ').downcase
      valores.include?('sello') || valores.include?('seal')
    end

    # NIF del titular, tal como lo graba la FNMT en el sujeto.
    #
    # Sirve para una comprobación que ahorra viajes: la AEAT exige que el titular
    # del certificado coincida con el ObligadoEmision, y si no coinciden responde
    # un 4104 "no está identificado" que parece decir que el NIF no existe.
    #
    # Es una heurística sobre formatos observados (serialNumber "IDCES-xxxxxxxxX"
    # o el NIF suelto, y CN terminado en "- xxxxxxxxX"), no un campo normalizado,
    # así que devuelve nil si no lo reconoce en vez de inventarse nada.
    PATRON_NIF = /\b([A-Z]?\d{7,8}[A-Z0-9])\b/

    def nif
      candidatos = [sujeto['serialNumber'], sujeto['CN']].compact
      candidatos.each do |valor|
        m = valor.upcase.sub(/\AIDCES-/, '').match(PATRON_NIF)
        return m[1] if m && m[1].length == 9
      end
      nil
    end

    # Nombre o razón social del titular, sin el NIF que la FNMT le pega al final
    # del CN ("GARCIA LOPEZ ANA - 89890001K").
    #
    # Importa porque la AEAT identifica al obligado por el PAR NIF + NombreRazon:
    # con el NIF correcto y un nombre que no cuadre responde 4104, y el mensaje
    # habla solo del NIF aunque en el detalle devuelva los dos campos.
    def titular
      cn = sujeto['CN']
      return nil if cn.nil?

      cn.sub(/\s*-\s*#{Regexp.escape(nif.to_s)}\s*\z/, '').strip
    end

    def resumen
      { titular: sujeto['CN'], organizacion: sujeto['O'],
        caduca: certificado.not_after, dias_restantes: dias_para_caducar,
        sello: sello? }
    end

    private

    def validar!
      unless certificado.is_a?(OpenSSL::X509::Certificate)
        raise CertificadoError, 'Certificado X509 no válido'
      end
      raise CertificadoError, 'Clave privada ausente en el PKCS12' if clave.nil?
      unless certificado.check_private_key(clave)
        raise CertificadoError, 'La clave privada no corresponde al certificado'
      end
      if caducado?
        raise CertificadoError,
              "Certificado caducado el #{certificado.not_after.strftime('%d-%m-%Y')}"
      end
    end
  end
end
