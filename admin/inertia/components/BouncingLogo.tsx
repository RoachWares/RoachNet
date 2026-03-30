import { useState, useEffect } from 'react'

// Fading Image Component
const FadingImage = ({ alt = 'RoachNet mark', className = '' }) => {
  const [isVisible, setIsVisible] = useState(true)
  const [shouldShow, setShouldShow] = useState(true)

  useEffect(() => {
    // Start fading out after 2 seconds
    const fadeTimer = setTimeout(() => {
      setIsVisible(false)
    }, 2000)

    // Remove from DOM after fade out completes
    const removeTimer = setTimeout(() => {
      setShouldShow(false)
    }, 3000)

    return () => {
      clearTimeout(fadeTimer)
      clearTimeout(removeTimer)
    }
  }, [])

  if (!shouldShow) {
    return null
  }

  return (
    <div className={`fixed inset-0 flex justify-center items-center bg-[#05080b] z-50 pointer-events-none transition-opacity duration-1000 ${
      isVisible ? 'opacity-100' : 'opacity-0'
    }`}>
      <img
        src="/roachnet-mark.png"
        alt={alt}
        className={`h-64 w-64 object-contain drop-shadow-[0_0_28px_rgba(0,255,102,0.26)] ${className}`}
      />
    </div>
  )
}

export default FadingImage
