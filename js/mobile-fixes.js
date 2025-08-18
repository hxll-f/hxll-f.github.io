// Mobile-specific JavaScript for portfolio items
$(document).ready(function() {
    // Check if device is mobile
    const isMobile = window.matchMedia("only screen and (max-width: 768px)").matches;
    
    if (isMobile) {
        // Handle click events on portfolio items
        $('.portfolio-item').on('click', function() {
            // Hide any other visible overlays
            $('.item_overlay.show').removeClass('show');
            
            // Toggle current overlay
            $(this).find('.item_overlay').toggleClass('show');
            
            // Hide overlay when clicking elsewhere
            $(document).on('click', function(event) {
                if (!$(event.target).closest('.portfolio-item').length) {
                    $('.item_overlay.show').removeClass('show');
                }
            });
        });
    }
});
