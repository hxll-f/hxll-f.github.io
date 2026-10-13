// Portfolio grid enhancement for handling different image orientations

$(window).load(function(){
  // Wait for images to load before initializing isotope
  setTimeout(function() {
    var $container = $('#portfolio_wrapper');
    
    // Initialize isotope with improved settings
    $container.isotope({
      itemSelector: '.portfolio-item',
      layoutMode: 'masonry', // Use masonry for better handling of different heights
      masonry: {
        columnWidth: '.portfolio-item', // Use item as column width reference
        gutter: 0 // No spacing between items
      }
    });
    
    // Filter functionality
    $('#filters a').click(function(){
      var selector = $(this).attr('data-filter');
      $container.isotope({ filter: selector });
      return false;
    });
    
    // Add active class to current filter
    $('#filters a').click(function(){
      $('#filters a').removeClass('active');
      $(this).addClass('active');
    });
    
    // Layout adjustment after images are loaded
    $container.imagesLoaded().progress(function() {
      $container.isotope('layout');
    });
  }, 100);
});
